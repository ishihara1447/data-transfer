#!/usr/bin/env bash
# /migfs ディレクトリの oracle:oinstall 権限設定
# docker-compose up -d 後に実行する
set -euo pipefail

docker exec -u root oracle-src bash -c "chown oracle:oinstall /migfs && chmod 750 /migfs"
docker exec -u root oracle-tgt bash -c "chown oracle:oinstall /migfs && chmod 750 /migfs"
echo "/migfs 権限設定完了"
