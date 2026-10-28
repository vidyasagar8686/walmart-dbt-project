{{ config(severity='error', store_failures=true) }}

-- Fails if any file CURRENTLY in S3 has a header that doesn't match its contract.
-- Headers are read once per file version by the control table file_header_log,
-- so this test reads only that table and the free directory list, not the files.
SELECT
    l.file_name,
    l.file_last_modified,
    l.file_type,
    l.actual_header,
    l.contract_version,
    l.expected_header,
    l.checked_at
FROM {{ ref('file_header_log') }} l
JOIN DIRECTORY(@WALMART.RAW.WALMART_S3_STAGE) d
  ON l.file_name          = 'raw/' || d.relative_path
 AND l.file_last_modified = d.last_modified
WHERE NOT l.header_ok