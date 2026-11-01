#!/bin/sh
# Publishes web/ to the live site or the staging copy. Usage: deploy/publish-web.sh prod|staging
set -e
cd "$(dirname "$0")/.."
FILES="index.html app.js core.js config.js style.css logo.png favicon.png apple-touch-icon.png hidelist.json"
case "$1" in
  prod) D=/srv/circ-web ;;
  staging) D=/srv/circ-staging ;;
  *) echo "usage: $0 prod|staging"; exit 1 ;;
esac
install -d "$D/vendor"
for f in $FILES; do install -m 644 "web/$f" "$D/$f"; done
install -m 644 web/vendor/ethers-6.13.4.umd.min.js "$D/vendor/"
if [ "$1" = staging ]; then
  install -m 644 deploy/staging-config.js "$D/config.js"
  ln -sfn /srv/circ-web/data "$D/data"
fi
echo "published to $D"
