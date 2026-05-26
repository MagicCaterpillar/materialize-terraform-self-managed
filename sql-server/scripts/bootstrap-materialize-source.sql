IF DB_ID(N'$(DB_NAME)') IS NULL
BEGIN
    PRINT 'Creating database $(DB_NAME)';
    DECLARE @create_db_sql nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(N'$(DB_NAME)') + N';';
    EXEC(@create_db_sql);
END
GO

DECLARE @snapshot_state tinyint;
SELECT @snapshot_state = snapshot_isolation_state
FROM sys.databases
WHERE name = N'$(DB_NAME)';

IF @snapshot_state <> 1
BEGIN
    PRINT 'Enabling ALLOW_SNAPSHOT_ISOLATION for $(DB_NAME)';
    DECLARE @enable_snapshot_sql nvarchar(max) =
        N'ALTER DATABASE ' + QUOTENAME(N'$(DB_NAME)') + N' SET ALLOW_SNAPSHOT_ISOLATION ON;';
    EXEC(@enable_snapshot_sql);
END
GO

DECLARE @rcsi_state bit;
SELECT @rcsi_state = is_read_committed_snapshot_on
FROM sys.databases
WHERE name = N'$(DB_NAME)';

IF @rcsi_state <> 1
BEGIN
    PRINT 'Enabling READ_COMMITTED_SNAPSHOT for $(DB_NAME)';
    DECLARE @enable_rcsi_sql nvarchar(max) =
        N'ALTER DATABASE ' + QUOTENAME(N'$(DB_NAME)') + N' SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;';
    EXEC(@enable_rcsi_sql);
END
GO

USE [master];
GO

DECLARE @mz_login sysname = N'$(MZ_LOGIN)';
DECLARE @mz_password nvarchar(256) = N'$(MZ_PASSWORD)';
DECLARE @rotate_password bit = CASE WHEN '$(ROTATE_LOGIN_PASSWORD)' = '1' THEN 1 ELSE 0 END;
DECLARE @create_login_sql nvarchar(max);
DECLARE @alter_login_sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = @mz_login)
BEGIN
    PRINT 'Creating login ' + @mz_login;
    SET @create_login_sql =
        N'CREATE LOGIN ' + QUOTENAME(@mz_login) +
        N' WITH PASSWORD = ' + QUOTENAME(@mz_password, '''') +
        N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
    EXEC(@create_login_sql);
END
ELSE
BEGIN
    IF @rotate_password = 1
    BEGIN
        PRINT 'Updating password for existing login ' + @mz_login;
        SET @alter_login_sql =
            N'ALTER LOGIN ' + QUOTENAME(@mz_login) +
            N' WITH PASSWORD = ' + QUOTENAME(@mz_password, '''') + N';';
        EXEC(@alter_login_sql);
    END
    ELSE
    BEGIN
        PRINT 'Login already exists; keeping existing password for ' + @mz_login;
    END
END
GO

DECLARE @mz_login sysname = N'$(MZ_LOGIN)';
DECLARE @grant_view_server_state_sql nvarchar(max) =
    N'GRANT VIEW SERVER STATE TO ' + QUOTENAME(@mz_login) + N';';
DECLARE @grant_view_server_perf_state_sql nvarchar(max) =
    N'GRANT VIEW SERVER PERFORMANCE STATE TO ' + QUOTENAME(@mz_login) + N';';

EXEC(@grant_view_server_state_sql);
EXEC(@grant_view_server_perf_state_sql);
GO

USE [$(DB_NAME)];
GO

DECLARE @db_name sysname = N'$(DB_NAME)';
DECLARE @db_user sysname = N'$(MZ_LOGIN)';
DECLARE @create_user_sql nvarchar(max);
DECLARE @grant_connect_sql nvarchar(max);
DECLARE @grant_view_state_sql nvarchar(max);
DECLARE @grant_datareader_sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @db_user)
BEGIN
    PRINT 'Creating database user ' + @db_user;
    SET @create_user_sql =
        N'CREATE USER ' + QUOTENAME(@db_user) +
        N' FOR LOGIN ' + QUOTENAME(@db_user) + N';';
    EXEC(@create_user_sql);
END

SET @grant_connect_sql = N'GRANT CONNECT TO ' + QUOTENAME(@db_user) + N';';
EXEC(@grant_connect_sql);

SET @grant_view_state_sql = N'GRANT VIEW DATABASE STATE TO ' + QUOTENAME(@db_user) + N';';
EXEC(@grant_view_state_sql);

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    INNER JOIN sys.database_principals role_principal ON drm.role_principal_id = role_principal.principal_id
    INNER JOIN sys.database_principals member_principal ON drm.member_principal_id = member_principal.principal_id
    WHERE role_principal.name = N'db_datareader' AND member_principal.name = @db_user
)
BEGIN
    SET @grant_datareader_sql = N'ALTER ROLE [db_datareader] ADD MEMBER ' + QUOTENAME(@db_user) + N';';
    EXEC(@grant_datareader_sql);
END

GO

IF '$(CREATE_SAMPLE_DATA)' = '1'
BEGIN
    DECLARE @sample_table_sql nvarchar(max) = N'
IF OBJECT_ID(''' + QUOTENAME(N'$(SOURCE_SCHEMA)') + N'.' + QUOTENAME(N'$(SOURCE_TABLE)') + N''', ''U'') IS NULL
BEGIN
    CREATE TABLE ' + QUOTENAME(N'$(SOURCE_SCHEMA)') + N'.' + QUOTENAME(N'$(SOURCE_TABLE)') + N' (
        id int IDENTITY(1,1) NOT NULL PRIMARY KEY,
        customer_id int NOT NULL,
        amount decimal(12,2) NOT NULL,
        status nvarchar(32) NOT NULL,
        created_at datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
    );

    INSERT INTO ' + QUOTENAME(N'$(SOURCE_SCHEMA)') + N'.' + QUOTENAME(N'$(SOURCE_TABLE)') + N' (customer_id, amount, status)
    VALUES
        (101, 49.95, N''new''),
        (102, 19.99, N''new''),
        (101, 120.00, N''paid'');
END;
';

    EXEC(@sample_table_sql);
END
GO

IF '$(ENABLE_CDC)' = '1'
BEGIN
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND is_cdc_enabled = 0)
    BEGIN
        PRINT 'Enabling CDC for database $(DB_NAME)';
        EXEC sys.sp_cdc_enable_db;
    END

    DECLARE @source_schema sysname = N'$(SOURCE_SCHEMA)';
    DECLARE @source_table sysname = N'$(SOURCE_TABLE)';

    IF OBJECT_ID(QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table), N'U') IS NULL
    BEGIN
        THROW 51000, 'Source table does not exist; set CREATE_SAMPLE_DATA=1 or create the table before enabling CDC.', 1;
    END

    IF NOT EXISTS (
        SELECT 1
        FROM cdc.change_tables
        WHERE source_object_id = OBJECT_ID(QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_table), N'U')
    )
    BEGIN
        PRINT 'Enabling CDC for table $(SOURCE_SCHEMA).$(SOURCE_TABLE)';
        EXEC sys.sp_cdc_enable_table
            @source_schema = @source_schema,
            @source_name = @source_table,
            @role_name = NULL,
            @supports_net_changes = 0;
    END

    DECLARE @grant_cdc_sql nvarchar(max) = N'GRANT SELECT ON SCHEMA::[cdc] TO ' + QUOTENAME(N'$(MZ_LOGIN)') + N';';
    EXEC(@grant_cdc_sql);
END
GO

PRINT 'SQL Server bootstrap complete.';
