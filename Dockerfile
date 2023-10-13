FROM node:18-alpine
LABEL "repository"="https://github.com/stargaze-061/github-tag-action"
LABEL "homepage"="https://github.com/stargaze-061/github-tag-action"
LABEL "maintainer"="Stargaze team"

RUN apk --no-cache add bash git curl jq && npm install -g semver

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
