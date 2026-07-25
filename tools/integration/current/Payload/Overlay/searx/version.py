# SPDX-License-Identifier: AGPL-3.0-or-later
# KI-Stack modification: avoid a VCS lookup in the installed Git-free payload.
from searx.version_frozen import VERSION_STRING, VERSION_TAG, DOCKER_TAG, GIT_URL, GIT_BRANCH

def get_information():
    return VERSION_STRING, VERSION_TAG, DOCKER_TAG, GIT_URL, GIT_BRANCH
