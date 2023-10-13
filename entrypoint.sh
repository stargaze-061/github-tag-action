#!/bin/bash

set -eo pipefail

# custom config
build_number=${BUILD_NUMBER:-true}
initial_build_number=${INITIAL_BUILD_NUMBER:-0}
prerelease_version=${PRERELEASE_VERSION:-true}

# config
default_branch=${DEFAULT_BRANCH:-$GITHUB_BASE_REF} # get the default branch from github runner env vars
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
git_api_tagging=${GIT_API_TAGGING:-true}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-false}
branch_history=${BRANCH_HISTORY:-compare}
# since https://github.blog/2022-04-12-git-security-vulnerability-announced/ runner uses?
git config --global --add safe.directory /github/workspace

cd "${GITHUB_WORKSPACE}/${source}" || exit 1

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BRANCH: ${default_branch}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tGIT_API_TAGGING: ${git_api_tagging}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tPRERELEASE_VERSION: ${prerelease_version}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tBRANCH_HISTORY: ${branch_history}"
echo -e "\tBUILD_NUMBER: ${BUILD_NUMBER}"
echo -e "\tINITIAL_BUILD_NUMBER: ${initial_build_number}"

# verbose, show everything
if $verbose
then
    set -x
fi

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)
echo "current_branch> $current_branch"

# fetch tags
git fetch --tags

res_count=30

# get the git refs
git_refs=
case "$tag_context" in
    *repo*)
        git_refs=$(git for-each-ref --count="$res_count" --sort=-v:refname --format '%(refname:lstrip=2)')
        ;;
    *branch*)
        git_refs=$(git tag --list --merged HEAD --sort=-committerdate |head -n "$res_count")
        ;;
    * ) echo "Unrecognised context"
        exit 1;;
esac

# get the latest tag that looks like a semver (with or without v)
tagFmt="^v?[0-9]+\.[0-9]+\.[0-9]+(-$suffix(\.[0-9]+)?)(\+([0-9]+))?"

matching_tag_refs=$( (grep -m "$res_count" -E "$tagFmt" <<< "$git_refs") || true)
tag=$(head -n 1 <<< "$matching_tag_refs")

echo "matching_tag_refs> $matching_tag_refs"
echo "tag> $tag"

buildNumFmt=".*\+([0-9]+)$"
latest_tag=$(git describe --tags `git rev-list --tags --max-count=1`)
echo "latest_tag> $latest_tag"

if $build_number
then
    if [[ $latest_tag =~ $buildNumFmt ]]; then current_build_number=${BASH_REMATCH[1]}; fi

    echo "current_build_number> $current_build_number"

    if [[ -z current_build_number ]]
    then
        next_build_number=$initial_build_number
    else
        next_build_number=$((current_build_number + 1))
    fi

    echo "next_build_number> $next_build_number"
fi

# if there are none, start tags at INITIAL_VERSION
if [ -z "$tag" ]
then
    tag="v$initial_version"
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 "$tag" || true )
# get current commit hash
commit=$(git rev-parse HEAD)
# skip if there are no new commits for non-pre_release
if [ "$tag_commit" == "$commit" ]
then
    echo "No new commits since previous tag. Skipping..."
    setOutput "new_tag" "$tag"
    setOutput "tag" "$tag"
    exit 0
fi

# sanitize that the default_branch is set (via env var when running on PRs) else find it natively
if [ -z "${default_branch}" ] && [ "$branch_history" == "full" ]
then
    echo "The DEFAULT_BRANCH should be autodetected when tag-action runs on on PRs else must be defined, See: https://github.com/anothrNick/github-tag-action/pull/230, since is not defined we find it natively"
    default_branch=$(git branch -rl '*/master' '*/main' | cut -d / -f2)
    echo "default_branch=${default_branch}"
    # re check this
    if [ -z "${default_branch}" ]
    then
        echo "::error::DEFAULT_BRANCH must not be null, something has gone wrong."
        exit 1
    fi
fi

new=$(semver "$tag")

# do not want prerelease tag versions   
if $prerelease_version
then
    # already a pre-release available, bump it
    if [[ "$tag" =~ $new ]] && [[ "$tag" =~ $suffix ]]
    then
        new=v$(semver -i prerelease "${tag}" --preid "${suffix}")
        echo -e "Bumping ${suffix} pre-tag ${tag}. New pre-tag ${new}"
    else
        new="v$new-$suffix.0"
        echo -e "Bumping ${suffix} pre-tag ${tag} with pre-tag ${new}"
    fi
    
else
    new="v$new"
    echo -e "Setting ${suffix} pre-tag ${tag} - With pre-tag ${new}"
fi

part="pre-$part"

# appending build bumber in metadata if needed
if [ $build_number = true ]
then
    new=$new'+'$next_build_number
    echo -e "Build number appended to version $new"
fi

# set outputs
setOutput "new_tag" "$new"
setOutput "part" "$part"
setOutput "tag" "$new" # this needs to go in v2 is breaking change
setOutput "old_tag" "$tag"

# dry run exit without real changes
if $dryrun
then
    exit 0
fi

echo "EVENT: creating local tag $new"
# create local git tag
git tag -f "$new" || exit 1
echo "EVENT: pushing tag $new to origin"

if $git_api_tagging
then
    # use git api to push
    dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
    full_name=$GITHUB_REPOSITORY
    git_refs_url=$(jq .repository.git_refs_url "$GITHUB_EVENT_PATH" | tr -d '"' | sed 's/{\/sha}//g')

    echo "$dt: **pushing tag $new to repo $full_name"

    git_refs_response=$(
    curl -s -X POST "$git_refs_url" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -d @- << EOF
{
    "ref": "refs/tags/$new",
    "sha": "$commit"
}
EOF
)

    git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

    echo "::debug::${git_refs_response}"
    if [ "${git_ref_posted}" = "refs/tags/${new}" ]
    then
        exit 0
    else
        echo "::error::Tag was not created properly."
        exit 1
    fi
else
    # use git cli to push
    git push -f origin "$new" || exit 1
fi