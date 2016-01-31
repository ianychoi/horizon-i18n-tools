#!/bin/bash
######################################################################
# Import translations from Zanata and reload Apache running Horizon
######################################################################

logger -i -t `basename $0` "Started ($*)"

RELEASE=master
HORIZON_REPO=/opt/stack/horizon
THRESH=30

DO_GIT_PULL=1

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
    echo "  -d WORKDIR : Horizon working git repo (Default: $HORIZON_REPO)"
    echo "  -m THRESH  : Minimum percentage of a translation (Default: $THRESH)"
    exit 1
}

while getopts b:d:m:r:h OPT; do
    case $OPT in
        b) TARGET_BRANCH=$OPTARG ;;
        d) HORIZON_REPO=$OPTARG ;;
        m) THRESH=$OPTARG ;;
        r) RELEASE=$OPTARG ;;
        h) usage_exit ;;
        \?) usage_exit ;;
    esac
done

if [ ! -n "$TARGET_BRANCH" ]; then
  if [ "$RELEASE" = "master" ]; then
    TARGET_BRANCH=$RELEASE
  else
    TARGET_BRANCH=stable/$RELEASE
  fi
fi

set -o xtrace

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



ZANATA_CMD=`which zanata-cli`
if [ ! -n "$ZANATA_CMD" ]; then
  echo "Zanata 'zanata-cli' command not found"
  exit 1
fi

# Check the amount of translation done for a .po file, sets global variable
# RATIO.
function check_po_file {
    local file=$1
    local dropped_ratio=$2

    trans=$(msgfmt --statistics -o /dev/null "$file" 2>&1)
    check="^0 translated messages"
    if [[ $trans =~ $check ]] ; then
        RATIO=0
    else
        if [[ $trans =~ " translated message" ]] ; then
            trans_no=$(echo $trans|sed -e 's/ translated message.*$//')
        else
            trans_no=0
        fi
        if [[ $trans =~ " untranslated message" ]] ; then
            untrans_no=$(echo $trans|sed -e 's/^.* \([0-9]*\) untranslated message.*/\1/')
        else
            untrans_no=0
        fi
        total=$(($trans_no+$untrans_no))
        RATIO=$((100*$trans_no/$total))
    fi
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
    $ZANATA_CMD -B -e pull


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

ORIGIN_DIR=$PWD
TOP_DIR=$(cd $(dirname "$0") && pwd)

cd $HORIZON_REPO

git checkout -- .tx
git checkout -- horizon/locale/
git checkout -- openstack_dashboard/locale/
git status | grep django.mo | xargs rm
git status | grep djangojs.mo | xargs rm
git status | grep django.po | xargs rm
git status | grep djangojs.po | xargs rm
git status | grep /locale/ | xargs rm -rf

if [ "$DO_GIT_PULL" -ne 0 ]; then
  git branch --set-upstream-to=remotes/origin/$TARGET_BRANCH $TARGET_BRANCH
  git checkout $TARGET_BRANCH
  git pull
  sudo pip install -e .
fi

setup_zanata_horizon $RELEASE

#$TX_CMD pull $TX_OPTS
pull_from_zanata $PROJECT $THRESH

cd horizon
../manage.py compilemessages
cd ..
cd openstack_dashboard
../manage.py compilemessages
cd ..

rm -f horizon/locale/en/LC_MESSAGES/django.mo
rm -f horizon/locale/en/LC_MESSAGES/djangojs.mo
rm -f openstack_dashboard/locale/en/LC_MESSAGES/django.mo

$TOP_DIR/update-lang-list.sh

DJANGO_SETTINGS_MODULE=openstack_dashboard.settings python manage.py collectstatic --noinput
DJANGO_SETTINGS_MODULE=openstack_dashboard.settings python manage.py compress --force

sudo service apache2 reload

logger -i -t `basename $0` "Completed."
