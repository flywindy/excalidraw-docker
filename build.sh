#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
CUSTOM=$(basename ${DIR})

source .env

MK="base nginx excalidraw excalidraw-room excalidraw-json"

BUILDREPO=${BUILDREPO:-localbuild}
SRC_REPO=$DIR/src_repo

# -------------------------------------------------------------------

PRE="------>"

mkdir -p ./data/{minio,nginx}

echo $PRE Checkout excalidraw repo...
if [ ! -d "$SRC_REPO/excalidraw" ]; then
    git clone https://github.com/excalidraw/excalidraw.git $SRC_REPO/excalidraw
    ln -s $SRC_REPO/excalidraw $DIR/excalidraw
fi

echo $PRE Checkout excalidraw-json repo...
if [ ! -d "$SRC_REPO/excalidraw-json" ]; then
    git clone https://github.com/NMinhNguyen/excalidraw-json.git $SRC_REPO/excalidraw-json
    sed -i "/origin: getOrigins(),/a \ \ methods: ['GET', 'HEAD', 'POST']," $SRC_REPO/excalidraw-json/src/server/corsMiddleware.ts
fi

echo $PRE Checkout excalidraw-room repo...
if [ ! -d "$SRC_REPO/excalidraw-room" ]; then
    git clone https://github.com/excalidraw/excalidraw-room.git $SRC_REPO/excalidraw-room
fi

echo $PRE Copying excalidraw-json Dockerfile...
cp $DIR/ressource/Dockerfile_excalidraw-json $SRC_REPO/excalidraw-json/Dockerfile

if [ -n "$(docker swarm join-token manager 2>&1 | grep 'not a swarm manager')" ]; then
    echo $PRE Initializing Docker swarm...
    docker swarm init
fi

if [ $(docker network ls | grep excalidraw-net | wc -l) = 0 ]; then
    echo $PRE Creating overlay network...
    docker network create --driver=overlay --attachable excalidraw-net
fi

echo $PRE Stopping all services...
docker-compose down

if [ "$1" == "--rebuild-all" ]; then
    echo $PRE Removing Docker images for excalidraw and excalidraw-json...
    docker rmi $BUILDREPO/excalidraw 2> /dev/null
    docker rmi $BUILDREPO/excalidraw-json 2> /dev/null
    docker rmi $BUILDREPO/excalidraw-room 2> /dev/null
    docker rmi $BUILDREPO/nginx 2> /dev/null
    docker rmi $BUILDREPO/base 2> /dev/null
    docker rmi minio/minio 2> /dev/null
    docker rmi minio/mc 2> /dev/null
fi

BUILDARG="--build-arg BUILDREPO=$BUILDREPO"
if [ -n "${PROXY}" ]; then
    BUILDARG="$BUILDARG --build-arg http_proxy=${PROXY}/ --build-arg https_proxy=${PROXY}/"
fi

for i in $MK; do
    echo $PRE Docker build local images $i...

    cd $SRC_REPO/$i

    [ ! -z "${REACT_APP_BACKEND_V1_GET_URL+x}" ]  && sed -i.bak '/REACT_APP_BACKEND_V1_GET_URL=/s#=.*#='"${REACT_APP_BACKEND_V1_GET_URL}"'#' .env 2> /dev/null
    [ ! -z "${REACT_APP_BACKEND_V2_GET_URL+x}" ]  && sed -i.bak '/REACT_APP_BACKEND_V2_GET_URL=/s#=.*#='"${REACT_APP_BACKEND_V2_GET_URL}"'#' .env 2> /dev/null
    [ ! -z "${REACT_APP_BACKEND_V2_POST_URL+x}" ] && sed -i.bak '/REACT_APP_BACKEND_V2_POST_URL=/s#=.*#='"${REACT_APP_BACKEND_V2_POST_URL}"'#' .env 2> /dev/null
    [ ! -z "${REACT_APP_SOCKET_SERVER_URL+x}" ]   && sed -i.bak '/REACT_APP_SOCKET_SERVER_URL=/s#=.*#='"${REACT_APP_SOCKET_SERVER_URL}"'#' .env 2> /dev/null
    [ ! -z "${REACT_APP_FIREBASE_CONFIG+x}" ]     && sed -i.bak '/REACT_APP_FIREBASE_CONFIG=/s#=.*#='"${REACT_APP_FIREBASE_CONFIG}"'#' .env 2> /dev/null

    docker build ${BUILDARG} -t $BUILDREPO/$i:latest .

done

cd $DIR

if [ ! -d $DIR/data/minio/excalidraw ]; then
    echo $PRE Initializing S3 excalidraw storage...
    docker-compose up -d minio

    for i in {1..5}; do
        printf '\rWaiting %2d/5 secs for Minio S3 server' $i
        sleep 1
    done
    printf '\n'

cat <<EOF | docker run --rm -i --entrypoint=/bin/sh --network="excalidraw-net" minio/mc
  /usr/bin/mc config host add myminio http://minio:9000 ${EXCALIDRAW_S3_ACCESS_KEY_ID} ${EXCALIDRAW_S3_SECRET_ACCESS_KEY};
  /usr/bin/mc mb myminio/excalidraw;
  /usr/bin/mc policy set download myminio/excalidraw;
  exit 0;
EOF

    docker-compose down
fi

