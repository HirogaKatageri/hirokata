SELECT '## brief';        SELECT fact, value FROM v_brief;
SELECT '## direction';    SELECT id, priority, projects_runnable, runnable_project_ids,
                                 requirements_done, requirements_total, title FROM v_goal_progress;
SELECT '## projects';     SELECT json_object('id',id,'goal',goal_id,'why',why,
                                 'isolation',isolation,'worktree',worktree_path,
                                 'title',title) FROM v_projects_runnable;
SELECT '## requirements'; SELECT id, status, tasks_done, tasks_total, tasks_open,
                                 tasks_blocked, tasks_failed, title FROM v_requirement_progress
                           WHERE status <> 'done';
SELECT '## in-flight';    SELECT json_object('id',id,'req',requirement_id,'who',who,
                                 'minutes',minutes,'title',title) FROM v_in_flight;
SELECT '## bounties';     SELECT json_object('id',id,'req',requirement_id,'p',priority,
                                 'who',who,'title',title) FROM v_open_bounties;
SELECT '## blocked';      SELECT json_object('id',id,'req',requirement_id,'status',status,
                                 'reason',reason,'title',title) FROM v_blocked_tasks;
SELECT '## bugs';         SELECT json_object('id',id,'sev',severity,'status',status,
                                 'by',found_by,'req',requirement_id,'title',title) FROM v_open_bugs;
SELECT '## failed';       SELECT json_object('id',id,'who',who,'waived',waived,
                                 'reason',COALESCE(reason,''),'title',title) FROM v_failed_tasks;
SELECT '## findings';     SELECT json_object('id',id,'task',task_id,'sev',severity,
                                 'disp',disposition,'by',reviewer,'at',
                                 COALESCE(file,'') || ':' || COALESCE(line,''),
                                 'what',summary) FROM v_open_findings;
SELECT '## coverage';     SELECT json_object('id',id,'risk',risk,'due',interval_days,
                                 'since',COALESCE(days_since,-1),'area',area) FROM v_coverage_due;
SELECT '## docs-stale';   SELECT json_object('slug',slug,'kind',kind,'subject',
                                 subject_type || ':' || subject_id,'moved',subject_moved_at,
                                 'title',title) FROM v_doc_stale;
SELECT '## undocumented'; SELECT json_object('id',id,'at',finished_at,'title',title)
                            FROM v_undocumented_work;
SELECT '## gates';        SELECT json_object('node',node_id,'req',requirement_id,
                                 'kind',kind,'prompt',prompt) FROM v_gates_pending;
SELECT '## approvals';    SELECT json_object('id',id,'req',requirement_id,'status',status,
                                 'gate',gate_node_id,'title',title)
                            FROM v_plans_pending_approval;
SELECT '## moved';        SELECT json_object('ts',ts,'actor',actor,'verb',verb,
                                 'type',subject_type,'id',subject_id,'title',subject_title,
                                 'phrase',phrase) FROM v_recent_activity
                           WHERE ts >= COALESCE(NULLIF((SELECT value FROM guild_state
                                                         WHERE key='last-checkin'),'null'),'')
                           ORDER BY ts DESC LIMIT 30;
