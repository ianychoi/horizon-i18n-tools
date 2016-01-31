#!/bin/bash

THRESH=95
WORKDIR=$HOME/horizon
RELEASE=master

usage_exit() {
    set +o xtrace
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -r RELEASE : Specify release name in lower case (e.g. juno, icehouse, ...)"
    echo "               (Default: $RELEASE)"
    echo "  -b BRANCH  : Specify a target branch name."
    echo "               If unspecified, it will be stable/RELEASE."
    echo "               (Default: stable/$RELEASE)"
    echo "  -d WORKDIR : Horizon working git repo (Default: $WORKDIR)"
    echo "  -m THRESH  : Minimum percentage of a translation (Default: $THRESH)"
    exit 1
}

while getopts b:d:m:r:h OPT; do
    case $OPT in
        b) BASE_BRANCH=$OPTARG ;;
        d) WORKDIR=$OPTARG ;;
        m) THRESH=$OPTARG ;;
        r) RELEASE=$OPTARG ;;
        h) usage_exit ;;
        \?) usage_exit ;;
    esac
done

set -o xtrace

if [ ! -n "$BASE_BRANCH" ]; then
    if [ $RELEASE = "master" ]; then
        BASE_BRANCH=$RELEASE
    else
        BASE_BRANCH=stable/$RELEASE
    fi
fi

if [ $RELEASE = "icehouse" ]; then
    INCLUDE_MO_FILE=1
else
    INCLUDE_MO_FILE=0
fi

export GIT_PAGER=
export DJANGO_SETTINGS_MODULE=openstack_dashboard.test.settings

ORIGIN_DIR=$PWD
PROJECT=horizon
SOURCE_LANG=en
WORK_BRANCH=translation-imports-for-$RELEASE

TOP_DIR=$(cd $(dirname $0) && pwd)

setup_horizon_repo_if_nonexist() {
    if [ -d $WORKDIR ]; then
        return
    fi
    git clone git://git.openstack.org/openstack/horizon.git $WORKDIR
}

setup_work_branch() {
    if `git branch | grep $WORK_BRANCH >/dev/null 2>&1`; then
        git checkout $WORK_BRANCH
    else
        git checkout -b $WORK_BRANCH remotes/origin/$BASE_BRANCH
    fi
}

# Setup project horizon for Zanata
# Originally, "setup_horizon" function in common_translation_update.sh
# from openstack-infra/project-config repository
function setup_zanata_horizon {
    local project=horizon
    local version=${1:-master}

    $ORIGIN_DIR/create-zanata-xml.py -p $project \
        -v $version --srcdir . --txdir . -r './horizon/locale/*.pot' \
        'horizon/locale/{locale_with_underscore}/LC_MESSAGES/{filename}.po' \
        -r './openstack_dashboard/locale/*.pot' \
        'openstack_dashboard/locale/{locale_with_underscore}/LC_MESSAGES/{filename}.po' \
        -e '.*/**' -f zanata.xml
}

cleanup_message_catalogs() {
    git reset -q HEAD -- horizon/locale/
    git reset -q HEAD -- openstack_dashboard/locale/
    git checkout -q -- horizon/locale/
    git checkout -q -- openstack_dashboard/locale/
    git status | grep django.mo | xargs --no-run-if-empty rm
    git status | grep djangojs.mo | xargs --no-run-if-empty rm
    git status | grep django.po | xargs --no-run-if-empty rm
    git status | grep djangojs.po | xargs --no-run-if-empty rm
    git status | grep /locale/ | xargs --no-run-if-empty rm -rf
}

remove_all_message_catalogs() {
    rm -rf openstack_dashboard/locale/*
    rm -rf horizon/locale/*
    git checkout -q -- openstack_dashboard/locale/$SOURCE_LANG/
    git checkout -q -- horizon/locale/$SOURCE_LANG/
}

update_pot_files() {
    ./run_tests.sh -q --makemessages
    git add --all horizon/locale/
    git add --all openstack_dashboard/locale/
}

compile_message_catalogs_if_necessary() {
    if [ $INCLUDE_MO_FILE -eq 1 ]; then
        ./run_tests.sh -q --compilemessages
        # Add compiled message catalogs
        git add --all horizon/locale/
        git add --all openstack_dashboard/locale/
    fi
}

remove_partial_languages() {
    # Unless all of three resource (horizon/django,
    # horizon/djangojs, openstack_dashboard.django) meet the threshold,
    # remove these languages.
    local lang
    local all_langs=$((ls -1 openstack_dashboard/locale; ls -1 horizon/locale) | sort | uniq)
    for lang in $all_langs; do
        if [ -e "horizon/locale/$lang/LC_MESSAGES/django.po" \
             -a -e "horizon/locale/$lang/LC_MESSAGES/djangojs.po" \
             -a -e "openstack_dashboard/locale/$lang/LC_MESSAGES/django.po" ]; then
            :
        else
            echo "Removing uncompleted language: $lang..."
            rm -rf horizon/locale/$lang
            rm -rf openstack_dashboard/locale/$lang
        fi
    done
}

filter_commits() {
    # Don't include files where the only things which have changed are
    # the creation date, the version number, the revision date,
    # comment lines, or diff file information.
    for f in `git diff --cached --name-only`; do
        if [ ! -e "$f" ]; then
            continue
        fi
        if [[ "$f" =~ "/django.mo" || "$f" =~ "/djangojs.mo" ]]; then
            continue
        fi
        # It's ok if the grep fails
        set +e
        changed=$(git diff --cached "$f" \
            | egrep -v "(POT-Creation-Date|Project-Id-Version|PO-Revision-Date|Last-Translator|Language-Team):" \
            | egrep -c "^([-+][^-+#])")
        set -e
        if [ $changed -eq 0 ]; then
            git reset -q "$f"
            git checkout -- "$f"
        fi
    done
}

show_stats() {
    local lang
    local all_langs=$((ls -1 openstack_dashboard/locale; ls -1 horizon/locale) | sort | uniq)
    for lang in $all_langs; do
        if [ "$lang" = "$SOURCE_LANG" ]; then
            continue
        fi
        echo "---------- $lang ----------"
        echo -n "horizon: "
        msgfmt -o /dev/null --statistics horizon/locale/$lang/LC_MESSAGES/django.po
        echo -n "horizon javascript: "
        msgfmt -o /dev/null --statistics horizon/locale/$lang/LC_MESSAGES/djangojs.po
        echo -n "openstack_dashboard: "
        msgfmt -o /dev/null --statistics openstack_dashboard/locale/$lang/LC_MESSAGES/django.po
    done
}

show_add_delete_files() {
    echo "------------------------------"
    echo "Added files:"
    git diff --cached --name-only --diff-filter=A
    echo ""
    echo "Deleted files:"
    git diff --cached --name-only --diff-filter=D
}

# Pull translation project from Zanata
# Modified from common_translation_update.sh
# in openstack-infra/project-config repository
function pull_from_zanata {
    local project=$1
    local percentage=$2

    # Since Zanata does not currently have an option to not download new
    # files, we download everything, and then remove new files that are not
    # translated enough.
    zanata-cli -B -e pull


    for i in $(find . -name '*.po' ! -path './.*' -prune | cut -b3-); do
        check_po_file "$i"
        # We want new files to be >{$percentage}% translated. The glossary and
        # common documents in openstack-manuals have that relaxed to
        # >8%.
        if [ $project = "openstack-manuals" ]; then
            case "$i" in
                *glossary*|*common*)
                    percentage=8
                    ;;
            esac
        fi
        if [ $RATIO -lt $percentage ]; then
            # This means the file is below the ratio, but we only want
            # to delete it, if it is a new file. Files known to git
            # that drop below 20% will be cleaned up by
            # cleanup_po_files.
            if ! git ls-files | grep -xq "$i"; then
                rm -f "$i"
            fi
        fi
    done
}

setup_horizon_repo_if_nonexist
cd $WORKDIR
cleanup_message_catalogs
setup_work_branch
git status
setup_zanata_horizon
remove_all_message_catalogs

update_pot_files
#tx pull -f -a --minimum-perc $THRESH
pull_from_zanata $PROJECT $THRESH
remove_partial_languages
git add --all horizon/locale/
git add --all openstack_dashboard/locale/
filter_commits

compile_message_catalogs_if_necessary
set +o xtrace
show_stats
show_add_delete_files

exit 0
