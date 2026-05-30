var cfg = {
    "_id": "rs",
    "version": 1,
    "members": [
        {
            "_id": 0,
            "host": "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017",
            "priority": 1
        }
    ]
};

rs.initiate(cfg, { force: true });
console.log('Waiting for replica set to initialize!');
while (true) {
    const status = rs.status();
    if (status.myState == 1) {
        console.log('Replica set fully initialized!');
        break;
    }
    sleep(2000);
}
