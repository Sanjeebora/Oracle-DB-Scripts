--------------------------------------------------------------------------------
-- t01_notify.sql   Notification routing, severity filtering, audit trail.
--
-- Runs entirely against the 'log' provider, so it proves the routing logic
-- without sending anything. To prove real delivery, set NOTIFY_PROVIDER to your
-- channel and run the last section of this script on its own.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n        NUMBER;
  l_status   VARCHAR2(10);
  l_body     CLOB;
  l_provider VARCHAR2(30) := pkg_mon.cfg('NOTIFY_PROVIDER');
  l_minsev   VARCHAR2(10) := pkg_mon.cfg('NOTIFY_MIN_SEVERITY');
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t01 notification routing');

  DELETE FROM mon_notify_log;
  COMMIT;

  ------------------------------------------------------- log provider records
  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'log');
  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY', 'INFO');

  pkg_mon.notify('WARNING', 'Smoke test', 'Body of the smoke test message.');
  COMMIT;

  SELECT COUNT(*) INTO l_n FROM mon_notify_log;
  pkg_mon_test.eq('notify wrote exactly one audit row', l_n, 1);

  SELECT status, body INTO l_status, l_body FROM mon_notify_log;
  pkg_mon_test.eqs('log provider marks the message LOGGED', l_status, 'LOGGED');
  pkg_mon_test.ok('message carries the database name',
                  INSTR(l_body, pkg_mon.db_name) > 0);
  pkg_mon_test.ok('message carries the severity tag',
                  INSTR(l_body, '[WARNING]') > 0);
  pkg_mon_test.ok('message carries the body text',
                  INSTR(l_body, 'Body of the smoke test message.') > 0);

  ------------------------------------------------------------ severity filter
  DELETE FROM mon_notify_log;
  COMMIT;

  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY', 'CRITICAL');
  pkg_mon.notify('INFO',     'Should be filtered', 'noise');
  pkg_mon.notify('WARNING',  'Should be filtered', 'noise');
  pkg_mon.notify('CRITICAL', 'Should pass',        'signal');
  COMMIT;

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE status = 'FILTERED';
  pkg_mon_test.eq('INFO and WARNING filtered below CRITICAL threshold', l_n, 2);

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE status <> 'FILTERED';
  pkg_mon_test.eq('CRITICAL still delivered', l_n, 1);

  ----------------------------------------------------- unknown provider fails
  DELETE FROM mon_notify_log;
  COMMIT;

  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY', 'INFO');
  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'carrier-pigeon');
  BEGIN
    pkg_mon.notify('WARNING', 'Bad provider', 'should raise');
    pkg_mon_test.ok('unknown provider raises to the caller', FALSE);
  EXCEPTION WHEN OTHERS THEN
    pkg_mon_test.ok('unknown provider raises to the caller', TRUE);
  END;
  COMMIT;

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE status = 'ERROR';
  pkg_mon_test.eq('failed delivery is still audited', l_n, 1);

  ----------------------------------------------------------------- restore
  pkg_mon.set_cfg('NOTIFY_PROVIDER',     NVL(l_provider, 'log'));
  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY', NVL(l_minsev, 'INFO'));
  pkg_mon_test.note('restored NOTIFY_PROVIDER = ' || pkg_mon.cfg('NOTIFY_PROVIDER'));
END;
/

PROMPT
PROMPT --- Live delivery check (only meaningful once a real provider is set)
PROMPT   EXEC pkg_mon.set_cfg('NOTIFY_PROVIDER','oci');;
PROMPT   EXEC pkg_mon.notify('INFO','Live delivery test','If you can read this, routing works.');;
PROMPT   SELECT status, err FROM mon_notify_log ORDER BY sent_at DESC FETCH FIRST 1 ROWS ONLY;;
