#!/usr/bin/env python3
import sys
import logging
from typing import Tuple

from pr_info import FORCE_TESTS_LABEL, PRInfo

TRUSTED_ORG_IDS = {
    85562337,  # BetterStackHQ
}
TRUSTED_CONTRIBUTORS = {
    "adikus",
    "gyfis"
}

OK_SKIP_LABELS = {"release", "pr-backport", "pr-cherrypick"}
CAN_BE_TESTED_LABEL = "can be tested"
DO_NOT_TEST_LABEL = "do not test"


def pr_is_by_trusted_user(pr_user_login, pr_user_orgs):
    if pr_user_login.lower() in TRUSTED_CONTRIBUTORS:
        logging.info("User '%s' is trusted", pr_user_login)
        return True

    logging.info("User '%s' is not trusted", pr_user_login)

    for org_id in pr_user_orgs:
        if org_id in TRUSTED_ORG_IDS:
            logging.info(
                "Org '%s' is trusted; will mark user %s as trusted",
                org_id,
                pr_user_login,
            )
            return True
        logging.info("Org '%s' is not trusted", org_id)

    return False


# Returns whether we should look into individual checks for this PR. If not, it
# can be skipped entirely.
# Returns can_run, description, labels_state
def should_run_ci_for_pr(pr_info: PRInfo) -> Tuple[bool, str, str]:
    # Consider the labels and whether the user is trusted.
    print("Got labels", pr_info.labels)
    if FORCE_TESTS_LABEL in pr_info.labels:
        print(f"Label '{FORCE_TESTS_LABEL}' set, forcing remaining checks")
        return True, f"Labeled '{FORCE_TESTS_LABEL}'", "pending"

    if DO_NOT_TEST_LABEL in pr_info.labels:
        print(f"Label '{DO_NOT_TEST_LABEL}' set, skipping remaining checks")
        return False, f"Labeled '{DO_NOT_TEST_LABEL}'", "success"

    if OK_SKIP_LABELS.intersection(pr_info.labels):
        return (
            True,
            "Don't try new checks for release/backports/cherry-picks",
            "success",
        )

    if CAN_BE_TESTED_LABEL not in pr_info.labels and not pr_is_by_trusted_user(
        pr_info.user_login, pr_info.user_orgs
    ):
        print(
            f"PRs by untrusted users need the '{CAN_BE_TESTED_LABEL}' label - please contact a member of the core team"
        )
        return False, "Needs 'can be tested' label", "failure"

    return True, "No special conditions apply", "pending"


def main():
    logging.basicConfig(level=logging.INFO)

    pr_info = PRInfo(need_orgs=True, pr_event_from_api=True, need_changed_files=True)
    # The case for special branches like backports and releases without created
    # PRs, like merged backport branches that are reset immediately after merge
    if pr_info.number == 0:
        print("::notice ::Cannot run, no PR exists for the commit")
        sys.exit(1)

    can_run, description, labels_state = should_run_ci_for_pr(pr_info)
    if can_run and OK_SKIP_LABELS.intersection(pr_info.labels):
        print("::notice :: Early finish the check, running in a special PR")
        sys.exit(0)

    if not can_run:
        print("::notice ::Cannot run")
        sys.exit(1)
    else:
        print("::notice ::Can run")


if __name__ == "__main__":
    main()
