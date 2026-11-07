#!/bin/sh
# Checks the restricted adapter user of the LOCAL broker (AB#7338): permissions, tags, local password, and the broker's own
# verdict for sample resource names (CK method resources refused, adapter names allowed). Read-only; no cluster credential.
#
# Usage:  verify-adapter-broker-user.sh [kind | docker[:<container>]]
#   kind               the kind cluster (kubectl context kind-kind, namespace octo-infra or $RABBITMQ_NAMESPACE, deployment rabbitmq) - default if it exists
#   docker[:<name>]    the docker-compose container (default name: rabbitmq)
# For the connection-level proof (consume/bind/declare/delete/publish refused, adapter bus works) see the integration test
# RestrictedAdapterUserTests in octo-distributedEventHub.
set -u

USER_NAME=octo-adapter-mq-user
LOCAL_PASSWORD=adapter
EXPECT_CONFIGURE='^(?!.*octo::method::).*$'
EXPECT_WRITE='^(?!amq[.]default$)(?!.*octo::method::).*$'
EXPECT_READ='^(?!.*octo::method::).*$'

target="${1:-}"
if [ -z "$target" ]; then
  if command -v kubectl >/dev/null 2>&1 && kubectl --context kind-kind -n "${RABBITMQ_NAMESPACE:-octo-infra}" get deploy rabbitmq >/dev/null 2>&1; then
    target=kind
  else
    target=docker
  fi
fi
case "$target" in
  kind) ctl() { kubectl --context kind-kind -n "${RABBITMQ_NAMESPACE:-octo-infra}" exec deploy/rabbitmq -- rabbitmqctl "$@"; } ;;
  docker) ctl() { docker exec rabbitmq rabbitmqctl "$@"; } ;;
  docker:*) c="${target#docker:}"; ctl() { docker exec "$c" rabbitmqctl "$@"; } ;;
  *) echo "unknown target '$target'" >&2; exit 2 ;;
esac

failed=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; failed=1; }

perms=$(ctl -q list_permissions -p / --formatter json 2>/dev/null)
users=$(ctl -q list_users --formatter json 2>/dev/null)
[ -n "$perms" ] || { echo "cannot read the broker ($target)" >&2; exit 2; }

case "$perms" in *"\"user\":\"$USER_NAME\",\"configure\":\"$EXPECT_CONFIGURE\",\"write\":\"$EXPECT_WRITE\",\"read\":\"$EXPECT_READ\""*) ok "permissions of $USER_NAME as expected" ;; *) bad "permissions of $USER_NAME differ from the expected patterns" ;; esac
case "$users" in *"\"user\":\"$USER_NAME\",\"tags\":[]"*) ok "$USER_NAME has no tags (no management access)" ;; *) bad "$USER_NAME missing or has tags" ;; esac
case "$perms" in *'"user":"guest","configure":".*","write":".*","read":".*"'*) ok "guest keeps full permissions (host services)" ;; *) bad "guest permissions changed" ;; esac

if ctl authenticate_user "$USER_NAME" "$LOCAL_PASSWORD" >/dev/null 2>&1; then ok "local password of $USER_NAME works"; else bad "local password of $USER_NAME rejected"; fi

# the broker's own verdict (rabbit_auth_backend_internal:check_resource_access) for sample names, all three permissions
check() { # permission kind name expected
  r=$(ctl -q eval "rabbit_auth_backend_internal:check_resource_access({auth_user, <<\"$USER_NAME\">>, [], none}, rabbit_misc:r(<<\"/\">>, $2, <<\"$3\">>), $1, #{})." 2>/dev/null | tail -1)
  if [ "$r" = "$4" ]; then ok "$1 $2 $3 -> $r"; else bad "$1 $2 $3 -> '$r' (expected $4)"; fi
}
for p in configure write read; do
  check $p queue    'test-octo::method::system.identity::user::changepassword-1' false
  check $p exchange 'test-octo::method::system.identity::user::changepassword-1::send' false
  check $p queue    'octo::method::a::b::c-1' false
  check $p queue    'test-octo::service::asset-repo-0f3a' true
  check $p exchange 'test-adapter::pipeline-command::send' true
done
check write exchange 'amq.default' false
check read  exchange 'amq.default' true

exit $failed
