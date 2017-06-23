## Foreign-Event load tests

### Starting the environment

Just `docker-compose up` in the root directory. This starts 3 MongooseIM nodes, 3 Amoc nodes, 1 InfluxDB and 1 Grafana container.
Grafana dashboard can be accessed at [`localhost:3000`](localhost:3000).

### MongooseIM

MongooseIM nodes are configured to run with `mim` domain. Their hostnames and container names are: `mim-1`, `mim-2` and `mim-3`.
Node names are `mongooseim@$HOSTNAME`. Each of them exposes has its 5222 port exposed to host machine (5222, 5223 and 5224 respectively).


### Amoc

There are three amoc containers `amoc-control`, `amoc-1` and `amoc-2` (these are also their hostnames). Node names are
`amoc@$HOSTNAME`. `amoc-control` is inteded to be Amoc master node.

### Running the load test

```bash
$ docker-compose up # set up environment
$ ./register.sh     # register users
$ ./upload.sh       # upload a one_to_one.erl scenario
$ docker exec -it amoc-control /home/amoc/amoc/bin/amoc remote_console # get into Amoc master node console
```

```erlang
erl> amoc_dist:do(one_to_one, 0, 9999)  %% start the scenario
```

You can view the metrics at [`localhost:3000`](localhost:3000)
