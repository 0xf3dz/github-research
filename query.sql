WITH push_commits AS (
    SELECT
      repo.id AS repo_id,
      repo.name AS repo_name,
      actor.login AS actor,
      created_at,
      FORMAT_TIMESTAMP('%Y-%m', created_at) AS month,
      (
        actor.login IN (
          'renovate[bot]','dependabot[bot]','github-actions[bot]',
          'pre-commit-ci[bot]','autofix-ci[bot]','release-please[bot]',
          'dotnet-maestro[bot]','hash-worker[bot]',
          'opensearch-changeset-bot[bot]','konflux-internal-p02[bot]',
          'red-hat-konflux[bot]','elastic-renovate-prod[bot]',
          'tinfoild[bot]','nsmbot','wolfi-bot','goreleaserbot',
          'github-copilot[bot]','devin-ai[bot]',
          'claude[bot]','coderabbitai[bot]','ellipsis-dev[bot]',
          'Copilot'
        )
        OR actor.login LIKE '%[bot]'
        OR actor.login LIKE '%-bot'
      ) AS is_bot,
      JSON_EXTRACT_SCALAR(c, '$.sha') AS commit_sha,
      (
        LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%claude%anthropic%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%copilot%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%devin ai%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%openhands%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%coderabbitai%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%ellipsis%'
        OR LOWER(JSON_EXTRACT_SCALAR(c, '$.message')) LIKE '%co-authored-by:%copilot autofix%'
      ) AS has_ai_trailer
    FROM `githubarchive.month.*`,
         UNNEST(JSON_EXTRACT_ARRAY(payload, '$.commits')) AS c
    WHERE _TABLE_SUFFIX BETWEEN '202409' AND '202509'
      AND type = 'PushEvent'
  ),

  fork_repos AS (
    SELECT DISTINCT
      CAST(JSON_EXTRACT_SCALAR(payload, '$.forkee.id') AS INT64) AS repo_id
    FROM `githubarchive.month.*`
    WHERE _TABLE_SUFFIX BETWEEN '202409' AND '202509'
      AND type = 'ForkEvent'
  ),

  window_commits_per_repo AS (
    SELECT
      repo_id,
      COUNT(*) AS window_total_commits,
      COUNT(DISTINCT actor) AS window_unique_contributors
    FROM push_commits
    WHERE NOT is_bot
    GROUP BY repo_id
  ),

  window_external_issues_per_repo AS (
    SELECT
      repo.id AS repo_id,
      COUNTIF(
        JSON_EXTRACT_SCALAR(payload, '$.issue.user.login') != SPLIT(repo.name, '/')[OFFSET(0)]
      ) AS window_external_issues_opened_total
    FROM `githubarchive.month.*`
    WHERE _TABLE_SUFFIX BETWEEN '202409' AND '202509'
      AND type = 'IssuesEvent'
      AND JSON_EXTRACT_SCALAR(payload, '$.action') = 'opened'
    GROUP BY repo.id
  ),

  qualifying_repos AS (
    SELECT repo_id
    FROM window_commits_per_repo
    WHERE window_total_commits >= 5
      AND window_unique_contributors >= 2
  ),

  monthly_commits AS (
    SELECT
      repo_id,
      repo_name,
      month,
      COUNTIF(NOT is_bot) AS total_commits,
      COUNTIF(NOT is_bot AND has_ai_trailer) AS ai_assisted_commits,
      COUNT(DISTINCT CASE WHEN NOT is_bot THEN actor END) AS unique_human_contributors
    FROM push_commits
    WHERE repo_id IN (SELECT repo_id FROM qualifying_repos)
    GROUP BY repo_id, repo_name, month
  ),

  issue_data AS (
    SELECT
      repo.id AS repo_id,
      repo.name AS repo_name,
      FORMAT_TIMESTAMP('%Y-%m', created_at) AS month,
      JSON_EXTRACT_SCALAR(payload, '$.action') AS action,
      JSON_EXTRACT_SCALAR(payload, '$.issue.user.login') AS issue_author
    FROM `githubarchive.month.*`
    WHERE _TABLE_SUFFIX BETWEEN '202409' AND '202509'
      AND type = 'IssuesEvent'
      AND JSON_EXTRACT_SCALAR(payload, '$.action') IN ('opened', 'closed')
      AND repo.id IN (SELECT repo_id FROM qualifying_repos)
  ),

  monthly_issues AS (
    SELECT
      repo_id,
      month,
      COUNTIF(action = 'opened') AS issues_opened,
      COUNTIF(action = 'closed') AS issues_closed,
      COUNTIF(action = 'opened'
        AND issue_author != SPLIT(repo_name, '/')[OFFSET(0)]) AS external_issues_opened,
      COUNTIF(action = 'closed'
        AND issue_author != SPLIT(repo_name, '/')[OFFSET(0)]) AS external_issues_closed
    FROM issue_data
    GROUP BY repo_id, month
  ),

  monthly_stars AS (
    SELECT
      repo.id AS repo_id,
      FORMAT_TIMESTAMP('%Y-%m', created_at) AS month,
      COUNT(*) AS stars_gained
    FROM `githubarchive.month.*`
    WHERE _TABLE_SUFFIX BETWEEN '202409' AND '202509'
      AND type = 'WatchEvent'
      AND repo.id IN (SELECT repo_id FROM qualifying_repos)
    GROUP BY repo.id, month
  ),

  panel_raw AS (
    SELECT
      mc.repo_id,
      mc.repo_name,
      mc.month,

      -- per-month commit metrics
      mc.total_commits,
      mc.ai_assisted_commits,
      SAFE_DIVIDE(mc.ai_assisted_commits, mc.total_commits) AS ai_assisted_proportion,
      mc.unique_human_contributors,
      IFNULL(ms.stars_gained, 0) AS stars_gained,

      -- per-month raw issue counts
      IFNULL(mi.issues_opened, 0) AS issues_opened,
      IFNULL(mi.issues_closed, 0) AS issues_closed,
      IFNULL(mi.external_issues_opened, 0) AS external_issues_opened,
      IFNULL(mi.external_issues_closed, 0) AS external_issues_closed,

      -- per-month derived maintenance outcomes
      IFNULL(mi.issues_opened, 0) - IFNULL(mi.issues_closed, 0) AS backlog_growth,
      IFNULL(mi.external_issues_opened, 0) - IFNULL(mi.external_issues_closed, 0) AS
  external_backlog_growth,
      SAFE_DIVIDE(IFNULL(mi.issues_closed, 0), IFNULL(mi.issues_opened, 0)) AS closure_rate,
      SAFE_DIVIDE(IFNULL(mi.external_issues_closed, 0), IFNULL(mi.external_issues_opened, 0)) AS
  external_closure_rate,
      CAST(IFNULL(mi.issues_closed, 0) > 0 AS INT64) AS any_closure,

      -- window-level repo attributes (post-export filter levers)
      wc.window_total_commits,
      wc.window_unique_contributors,
      IFNULL(we.window_external_issues_opened_total, 0) AS window_external_issues_opened_total,
      IF(f.repo_id IS NOT NULL, TRUE, FALSE) AS is_fork
    FROM monthly_commits mc
    LEFT JOIN monthly_issues mi  ON mc.repo_id = mi.repo_id AND mc.month = mi.month
    LEFT JOIN monthly_stars ms   ON mc.repo_id = ms.repo_id AND mc.month = ms.month
    LEFT JOIN window_commits_per_repo wc          ON mc.repo_id = wc.repo_id
    LEFT JOIN window_external_issues_per_repo we  ON mc.repo_id = we.repo_id
    LEFT JOIN fork_repos f                         ON mc.repo_id = f.repo_id
  ),

  panel AS (
    SELECT
      *,
      -- cumulative within-window backlog (sums over panel rows for this repo)
      SUM(backlog_growth) OVER (
        PARTITION BY repo_id ORDER BY month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_open_issues,
      SUM(external_backlog_growth) OVER (
        PARTITION BY repo_id ORDER BY month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_external_open_issues
    FROM panel_raw
  )

  SELECT *
  FROM panel
  ORDER BY repo_id, month
