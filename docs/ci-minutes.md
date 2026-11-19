# GitLab CI minutes and maintenance releases

Every release on GitLab runs a release build on the namespace's CI minutes (400 a month on
the Free tier). When the month's use runs high,
[maintenance releases](decisions.md#maintenance-releases) on GitLab slow from weekly to
every four weeks. GitHub and Forgejo runs never query anything, and security releases never
wait.

## The check

The check runs only before a maintenance release whose last tag is at least
`AUTO_RELEASE_MAINTENANCE_DAYS` (default 7) and less than
`AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` (default 28) days old. It reads the
namespace's `ciMinutesUsage` for the current month from GitLab's GraphQL API
(`CI_API_GRAPHQL_URL`, else `$CI_SERVER_URL/api/graphql`, else
`https://gitlab.com/api/graphql`).

It projects the minutes used so far linearly to the end of the month:

```text
projected = used × days in the month ÷ day of the month
```

When the projection is more than `AUTO_RELEASE_MINUTES_BUDGET_PCT` (default 85) percent of
`AUTO_RELEASE_MINUTES_QUOTA` (default 400), the maintenance release waits until the tag is
`AUTO_RELEASE_MAINTENANCE_DAYS_OVER_BUDGET` days old. Setting either variable to `0` turns
the check off.

## The token

The query needs `CI_MINUTES_TOKEN`, a masked CI/CD variable holding a personal access token
with the `read_api` scope. GitLab's API cannot create a token with that scope, so create it
in the UI (Preferences → Access tokens). The query reads the usage of the token owner's
personal namespace.

Without the token, or when the query fails, the run logs why and keeps the shorter period.
In the GitLab component the budget is the `minutes_budget_pct` input.
