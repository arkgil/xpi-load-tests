#!/bin/sh

docker exec -it mim-1 /usr/lib/mongooseim/bin/mongooseimctl import_users /member/users.csv
