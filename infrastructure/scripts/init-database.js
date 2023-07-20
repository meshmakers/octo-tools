var cfg = {
    "_id": "rs",
    "version": 1,
    "members": [
        {
            "_id": 0,
            "host": "mongo-0.mongo:27017",
            "priority": 2
        },
        {
            "_id": 1,
            "host": "mongo-1.mongo:27017",
            "priority": 0
        },
        {
            "_id": 2,
            "host": "mongo-2.mongo:27017",
            "priority": 0
        }
    ]
};
rs.initiate(cfg, { force: true });
