SELECT replace(replace(replace(json_object(
  'brief', (SELECT json_group_array(json_object('fact',fact,'value',value)) FROM v_brief),
  'goals', (SELECT json_group_array(json_object('id',id,'status',status,'priority',priority,
              'projects',projects_total,'projects_done',projects_done,
              'runnable',projects_runnable,'runnable_ids',runnable_project_ids,
              'done',requirements_done,'total',requirements_total,'title',title))
            FROM (SELECT * FROM v_goal_progress ORDER BY priority, id)),
  'projects', (SELECT json_group_array(json_object('id',id,'goal',goal_id,'ordinal',ordinal,
              'status',status,'priority',priority,'concurrent',concurrent,
              'isolation',isolation,'worktree',worktree_path,'runnable',runnable,
              'reqs',requirements_total,'reqs_done',requirements_done,
              'open',tasks_open,'blocked',tasks_blocked,'title',title))
            FROM (SELECT * FROM v_project_progress)),
  'requirements', (SELECT json_group_array(json_object('id',id,'project',COALESCE(project_id,''),
              'status',status,'priority',priority,'total',tasks_total,'done',tasks_done,
              'open',tasks_open,'blocked',tasks_blocked,'failed',tasks_failed,'title',title))
            FROM (SELECT * FROM v_requirement_progress)),
  'tasks', (SELECT json_group_array(json_object('section',section,'n',section_no,'id',id,
              'status',status,'who',who,'req',requirement_id,'priority',priority,'title',title))
            FROM (SELECT * FROM v_board)),
  'blocked', (SELECT json_group_array(json_object('id',id,'reason',reason))
            FROM (SELECT * FROM v_blocked_tasks)),
  'approvals', (SELECT json_group_array(json_object('id',id,'req',requirement_id,
              'status',status,'gate',gate_node_id,'title',title))
            FROM (SELECT * FROM v_plans_pending_approval)),
  'nodes', (SELECT json_group_array(json_object('id',id,'req',requirement_id,'key',node_key,
              'kind',kind,'status',status,'task',COALESCE(task_id,''),
              'group',COALESCE(parallel_group,'')))
            FROM (SELECT * FROM graph_node ORDER BY requirement_id, id)),
  'edges', (SELECT json_group_array(json_object('from',from_node,'to',to_node))
            FROM (SELECT * FROM graph_edge ORDER BY from_node, to_node)),
  'gates', (SELECT json_group_array(json_object('node',node_id,'kind',kind,'status',status,
              'prompt',prompt,'decision',COALESCE(decision,''),'decided',COALESCE(decided_at,'')))
            FROM (SELECT * FROM gate ORDER BY node_id)),
  'bugs', (SELECT json_group_array(json_object('id',id,'severity',severity,'status',status,
              'by',found_by,'req',COALESCE(requirement_id,''),'fix',COALESCE(fix_task_id,''),
              'created',created_at,'title',title))
            FROM (SELECT * FROM bug ORDER BY id)),
  'findings', (SELECT json_group_array(json_object('id',id,'task',task_id,'reviewer',reviewer,
              'severity',severity,'disposition',disposition,'file',COALESCE(file,''),
              'line',COALESCE(line,0),'fix',COALESCE(fix_task_id,''),'created',created_at,
              'summary',summary,'detail',COALESCE(detail,'')))
            FROM (SELECT * FROM review_finding ORDER BY id)),
  'coverage', (SELECT json_group_array(json_object('id',id,'area',area,'risk',risk,
              'spec',COALESCE(spec_path,''),'last',COALESCE(last_inspected_at,''),
              'notes',COALESCE(notes,'')))
            FROM (SELECT * FROM coverage ORDER BY id)),
  'docs', (SELECT json_group_array(json_object('slug',slug,'title',title,'kind',kind,
              'status',status,'area',area,'source',source,'created',created_at,
              'updated',updated_at,'revisions',revisions,'edges',edges))
            FROM (SELECT * FROM v_doc_current)),
  'decisions', (SELECT json_group_array(json_object('slug',slug,'title',title,'status',status,
              'area',area,'created',created_at,'supersedes',supersedes,
              'superseded_by',superseded_by,'governs',governs,'revisions',revisions))
            FROM (SELECT * FROM v_decision_log)),
  'links', (SELECT json_group_array(json_object('rel',rel,'from_type',from_type,'from',from_id,
              'to_type',to_type,'to',to_id,'note',note,'by',created_by))
            FROM (SELECT * FROM knowledge_edge ORDER BY id)),
  'docs_stale', (SELECT json_group_array(json_object('slug',slug,'title',title,'kind',kind,
              'rel',rel,'subject_type',subject_type,'subject',subject_id,
              'doc_updated',doc_updated_at,'subject_moved',subject_moved_at))
            FROM (SELECT * FROM v_doc_stale)),
  'undocumented', (SELECT json_group_array(json_object('id',id,'title',title,
              'project',COALESCE(project_id,''),'finished',finished_at,'tasks',tasks_done))
            FROM (SELECT * FROM v_undocumented_work)),
  'activity', (SELECT json_group_array(json_object('ts',ts,'actor',actor,'verb',verb,
              'type',subject_type,'subject',subject_id,'title',subject_title,'phrase',phrase))
            FROM (SELECT * FROM v_recent_activity LIMIT 200))
),
  '&', char(92) || 'u0026'),
  '<', char(92) || 'u003c'),
  '>', char(92) || 'u003e');
