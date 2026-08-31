--------------------------------------------------------------------------------
-- t02_alerts.sql   Alert lifecycle: dedupe, cooldown, resolve, auto-close.
--
-- This is the logic that decides whether the pack is useful or gets muted, so it
-- gets the most assertions.
--------------------------------------------------------------------------------
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

DECLARE
  l_n     NUMBER;
  l_occ   NUMBER;
  l_state VARCHAR2(10);
  l_key   VARCHAR2(200) := 'TEST_ALERT_LIFECYCLE';
BEGIN
  pkg_mon_test.require_test_mode;
  pkg_mon_test.section('t02 alert lifecycle');

  DELETE FROM mon_alert      WHERE alert_key LIKE 'TEST!_%' ESCAPE '!';
  DELETE FROM mon_notify_log;
  COMMIT;

  pkg_mon.set_cfg('NOTIFY_PROVIDER', 'log');
  pkg_mon.set_cfg('NOTIFY_MIN_SEVERITY', 'INFO');
  pkg_mon.set_cfg('ALERT_COOLDOWN_MIN', '30');

  ------------------------------------------------------------- first sighting
  pkg_mon.raise_alert(l_key, 'WARNING', 'First sighting', 'detail one');

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = l_key AND state = 'OPEN';
  pkg_mon_test.eq('one open alert created', l_n, 1);

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE title LIKE '%First sighting%';
  pkg_mon_test.eq('first sighting notifies immediately', l_n, 1);

  --------------------------------------------------- repeat inside the cooldown
  pkg_mon.raise_alert(l_key, 'WARNING', 'Second sighting', 'detail two');
  pkg_mon.raise_alert(l_key, 'WARNING', 'Third sighting',  'detail three');

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = l_key;
  pkg_mon_test.eq('repeats do not create duplicate rows', l_n, 1);

  SELECT occurrences INTO l_occ FROM mon_alert WHERE alert_key = l_key;
  pkg_mon_test.eq('occurrence counter tracks repeats', l_occ, 3);

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE title NOT LIKE '%RESOLVED%';
  pkg_mon_test.eq('cooldown suppresses repeat notifications', l_n, 1);

  --------------------------------------------------- cooldown window expires
  UPDATE mon_alert
     SET notified_at = SYSTIMESTAMP - INTERVAL '2' HOUR
   WHERE alert_key = l_key;
  COMMIT;

  pkg_mon.raise_alert(l_key, 'WARNING', 'Fourth sighting', 'detail four');

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE title NOT LIKE '%RESOLVED%';
  pkg_mon_test.eq('notification resumes after the cooldown expires', l_n, 2);

  ---------------------------------------------------------------- resolution
  pkg_mon.clear_alert(l_key);

  SELECT state INTO l_state FROM mon_alert WHERE alert_key = l_key;
  pkg_mon_test.eqs('clear_alert closes the alert', l_state, 'CLOSED');

  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE title LIKE '%RESOLVED%';
  pkg_mon_test.eq('closing sends a resolution message', l_n, 1);

  -- Closing something already closed must be silent, not an error and not a
  -- second "resolved" message.
  pkg_mon.clear_alert(l_key);
  SELECT COUNT(*) INTO l_n FROM mon_notify_log WHERE title LIKE '%RESOLVED%';
  pkg_mon_test.eq('closing twice does not double-notify', l_n, 1);

  --------------------------------------------- reopening after a closed cycle
  pkg_mon.raise_alert(l_key, 'CRITICAL', 'Back again', 'detail five');

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = l_key AND state = 'OPEN';
  pkg_mon_test.eq('the same key can reopen as a new alert', l_n, 1);

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = l_key;
  pkg_mon_test.eq('the closed history row is retained', l_n, 2);

  SELECT occurrences INTO l_occ
    FROM mon_alert WHERE alert_key = l_key AND state = 'OPEN';
  pkg_mon_test.eq('the reopened alert starts its own count', l_occ, 1);

  ----------------------------------------------------------------- auto close
  pkg_mon.set_cfg('ALERT_AUTOCLOSE_MIN', '60');
  UPDATE mon_alert
     SET last_seen_at = SYSTIMESTAMP - INTERVAL '3' HOUR
   WHERE alert_key = l_key AND state = 'OPEN';
  COMMIT;

  pkg_mon.autoclose_alerts;

  SELECT COUNT(*) INTO l_n FROM mon_alert WHERE alert_key = l_key AND state = 'OPEN';
  pkg_mon_test.eq('stale open alerts are auto-closed', l_n, 0);

  --------------------------------------------- severity is carried through
  pkg_mon.raise_alert('TEST_SEV_CRIT', 'CRITICAL', 'Critical thing', 'x');
  SELECT COUNT(*) INTO l_n
    FROM v_mon_open_alerts WHERE alert_key = 'TEST_SEV_CRIT' AND severity = 'CRITICAL';
  pkg_mon_test.eq('open alerts view reports severity', l_n, 1);

  ------------------------------------------------------------------- cleanup
  DELETE FROM mon_alert WHERE alert_key LIKE 'TEST!_%' ESCAPE '!';
  DELETE FROM mon_notify_log;
  COMMIT;
END;
/
