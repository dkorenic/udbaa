SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO



CREATE PROCEDURE [sync].[PushLoginsToServer]
    @serverName nvarchar(64)
  , @print tinyint = 0
  , @dryRun bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @print > 0
        PRINT CONCAT('@serverName: ', @serverName);

    DECLARE @ctx varbinary(128) = CAST(OBJECT_NAME(@@PROCID) AS varbinary(128));
    SET CONTEXT_INFO @ctx;

    IF @print > 0
    BEGIN
        PRINT '';
        PRINT OBJECT_NAME(@@PROCID);
    END;

    DECLARE @sql    nvarchar(MAX)
          , @proc   nvarchar(MAX)
          , @domain nvarchar(64)
          , @rc     int;

    SET @proc = CONCAT(QUOTENAME(@serverName), '.', QUOTENAME(DB_NAME()), '.sys.sp_executesql');

    IF @print > 0
        PRINT CONCAT('@proc: ', @proc);


    /* prep remote structures */
    SET @sql = '
IF SCHEMA_ID(''tmp'') IS NULL EXEC(''CREATE SCHEMA [tmp]'');

IF OBJECT_ID(''[tmp].[dbo.Logins]'') IS NOT NULL EXEC(''DROP TABLE [tmp].[dbo.Logins]'');
SELECT TOP (0) * INTO [tmp].[dbo.Logins] FROM dbo.Logins;

SET @domain = DEFAULT_DOMAIN();
'   ;
    IF @print > 1
        PRINT @sql;

    IF @dryRun = 0
        EXEC @proc @sql, N'@domain nvarchar(64) OUT', @domain = @domain OUT;

    IF @print > 0
        PRINT CONCAT('@domain: ', @domain);

    /* push filtered Logins */
    SET @sql = CONCAT('INSERT INTO ', QUOTENAME(@serverName), '.', QUOTENAME(DB_NAME()), '.[tmp].[dbo.Logins] SELECT * FROM dbo.Logins WHERE RowId IN (SELECT RowId FROM dbo.FilterLogins(@domain, @serverName)); SET @rc = @@ROWCOUNT;');
    IF @print > 1
        PRINT @sql;
    IF @dryRun = 0
        EXEC sys.sp_executesql @sql
                             , N'@domain nvarchar(64), @serverName nvarchar(64), @rc int OUT'
                             , @domain = @domain
                             , @serverName = @serverName
                             , @rc = @rc OUT;
    IF @print > 0
        PRINT CONCAT('pushed: ', @rc);

    /* merge pushed logins */
    SET @sql = CONCAT(CAST('' AS nvarchar(MAX)), '
	DECLARE @actions TABLE (act nvarchar(10));

	WITH d AS (
        SELECT *
             , CHECKSUM(*) AS _chk
        FROM dbo.Logins
    )
       , s AS (
        SELECT *
             , CHECKSUM(*) AS _chk
        FROM [tmp].[dbo.Logins]
    )
	-- SELECT * FROM s JOIN d ON d.RowId = s.RowId;
    MERGE INTO d
    USING s
    ON d.RowId = s.RowId
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (RowId, DomainName, ServerName, Persona, LoginName, LoginSystemType, LoginSID, LoginPasswordHash, IsActive, LoginPasswordLastSetTimeUtc) VALUES
               (s.RowId, s.DomainName, s.ServerName, s.Persona, s.LoginName, s.LoginSystemType, s.LoginSID, s.LoginPasswordHash, s.IsActive, s.LoginPasswordLastSetTimeUtc)
    WHEN MATCHED AND d._chk != s._chk THEN
        UPDATE SET d.DomainName = s.DomainName
                 , d.ServerName = s.ServerName
                 , d.Persona = s.Persona
                 , d.LoginName = s.LoginName
                 , d.LoginSystemType = s.LoginSystemType
                 , d.LoginSID = s.LoginSID
                 , d.LoginPasswordHash = s.LoginPasswordHash
                 , d.IsActive = s.IsActive
                 , d.LoginPasswordLastSetTimeUtc = s.LoginPasswordLastSetTimeUtc
    WHEN NOT MATCHED BY SOURCE THEN DELETE
	OUTPUT $action INTO @actions (act)
	;

	SELECT 
		@deleted = ISNULL(SUM(IIF(act = ''DELETE'', 1, 0)), 0), 
		@updated = ISNULL(SUM(IIF(act = ''UPDATE'', 1, 0)), 0), 
		@inserted = ISNULL(SUM(IIF(act = ''INSERT'', 1, 0)), 0)
	FROM 
		@actions;

	');
    IF @print > 1
        PRINT @sql;
    
	DECLARE @deleted  int
          , @updated  int
          , @inserted int;

    IF @dryRun = 0
	BEGIN
        EXEC @proc @sql
                 , N'@deleted int OUT, @updated int OUT, @inserted int OUT'
                 , @deleted = @deleted OUT
                 , @updated = @updated OUT
                 , @inserted = @inserted OUT;

		IF @print > 0
		BEGIN
			PRINT CONCAT('@deleted: ', @deleted);
			PRINT CONCAT('@updated: ', @updated);
			PRINT CONCAT('@inserted: ', @inserted);
		END
	END
END;

GO
