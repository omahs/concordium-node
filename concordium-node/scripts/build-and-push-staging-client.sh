#!/usr/bin/env bash

# Temporary build script for Jenkins

set -e
./scripts/download-genesis-data.sh

VERSION=$(cat Cargo.toml | grep "version = \"" | head -n1 | sed 's/version = \"//' | sed 's/\"//')
VERSION_TAG=$(git rev-parse --verify HEAD)
CONSENSUS_VERSION=$(cd deps/internal/consensus && git rev-parse --verify HEAD)

echo $CONSENSUS_VERSION > CONSENSUS_VERSION

echo "Consensus commit ID $CONSENSUS_VERSION w/default type"

docker build  --build-arg consensus_type=default --ssh default -t concordium/staging-client:$VERSION -f scripts/staging-net-client.Dockerfile . --no-cache

docker save concordium/staging-client:$VERSION | gzip > staging-client-$VERSION.tar.gz
echo $VERSION > VERSION

aws s3 cp staging-client-$VERSION.tar.gz s3://distribution.concordium.com/ --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers
aws s3 cp VERSION s3://distribution.concordium.com/ --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers