#!/bin/bash

mongo <<EOF
   use admin;
   admin = db.getSiblingDB("admin");
   admin.createUser(
     {
	      user: "octo-system-admin",
        pwd: "OctoAdmin1",
        roles: [ { role: "root", db: "admin" } ]
     });
     db.getSiblingDB("admin").auth("octo-system-admin", "OctoAdmin1");
     rs.status();
EOF