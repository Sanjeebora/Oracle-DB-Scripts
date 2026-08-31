--------------------------------------------------------------------------------
-- dbms_cloud_stub.sql
--
-- ############################################################################
-- ##  DO NOT RUN THIS ON AN AUTONOMOUS DATABASE.                            ##
-- ##                                                                        ##
-- ##  It creates packages named DBMS_CLOUD and DBMS_CLOUD_TYPES inside the   ##
-- ##  DBMON schema. On a real ADB those local names would shadow the genuine ##
-- ##  Oracle packages for this schema, and every OCI call would silently do  ##
-- ##  nothing. This file exists only so PKG_MON_OCI can be compiled and unit ##
-- ##  tested on a plain Oracle instance that has no DBMS_CLOUD at all.       ##
-- ############################################################################
--
-- The stub returns an empty response. That is deliberate: the offline tests
-- exercise parsing and evaluation by handing captured payloads straight to
-- load_backups and load_db_details, never by pretending to make a network call.
--------------------------------------------------------------------------------
SET DEFINE OFF

CREATE OR REPLACE PACKAGE dbms_cloud_types AS
  TYPE resp IS RECORD (
    status_code NUMBER,
    body        CLOB
  );
END dbms_cloud_types;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE dbms_cloud AS

  method_get    CONSTANT VARCHAR2(8) := 'GET';
  method_post   CONSTANT VARCHAR2(8) := 'POST';
  method_put    CONSTANT VARCHAR2(8) := 'PUT';
  method_delete CONSTANT VARCHAR2(8) := 'DELETE';
  method_head   CONSTANT VARCHAR2(8) := 'HEAD';

  FUNCTION send_request (credential_name IN VARCHAR2,
                         uri             IN VARCHAR2,
                         method          IN VARCHAR2,
                         headers         IN CLOB    DEFAULT NULL,
                         body            IN BLOB    DEFAULT NULL)
    RETURN dbms_cloud_types.resp;

  FUNCTION get_response_status_code (resp IN dbms_cloud_types.resp) RETURN NUMBER;
  FUNCTION get_response_text        (resp IN dbms_cloud_types.resp) RETURN CLOB;

END dbms_cloud;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY dbms_cloud AS

  FUNCTION send_request (credential_name IN VARCHAR2,
                         uri             IN VARCHAR2,
                         method          IN VARCHAR2,
                         headers         IN CLOB    DEFAULT NULL,
                         body            IN BLOB    DEFAULT NULL)
    RETURN dbms_cloud_types.resp IS
    l_resp dbms_cloud_types.resp;
  BEGIN
    -- 599 is not a real OCI status. It makes it obvious in MON_JOB_LOG that a
    -- stub answered, rather than looking like a genuine authorisation failure.
    l_resp.status_code := 599;
    l_resp.body        := '{"stub":"no network call was made"}';
    RETURN l_resp;
  END send_request;

  FUNCTION get_response_status_code (resp IN dbms_cloud_types.resp) RETURN NUMBER IS
  BEGIN
    RETURN resp.status_code;
  END get_response_status_code;

  FUNCTION get_response_text (resp IN dbms_cloud_types.resp) RETURN CLOB IS
  BEGIN
    RETURN resp.body;
  END get_response_text;

END dbms_cloud;
/
SHOW ERRORS

PROMPT
PROMPT Stubs installed. Remember: these must never exist on a real ADB.
PROMPT Remove them with:
PROMPT   DROP PACKAGE dbms_cloud;;
PROMPT   DROP PACKAGE dbms_cloud_types;;
