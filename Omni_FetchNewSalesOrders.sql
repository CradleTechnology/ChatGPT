USE [GraniteDatabase]
GO

/****** Object:  StoredProcedure [dbo].[Omni_FetchNewSalesOrders]    Script Date: 07/02/2025 06:40:17 ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



CREATE   PROCEDURE [dbo].[Omni_FetchNewSalesOrders] as

DECLARE @HttpStatus VARCHAR(60);
DECLARE @HttpStatusText VARCHAR(60);
DECLARE @HttpResponseText VARCHAR(max);

DECLARE @IP varchar(20) = '172.30.5.4'
DECLARE @PortNumber varchar(10) = '51968'
DECLARE @User varchar(20) = 'automate'
DECLARE @Password varchar(20) = 'auto123'
--DECLARE @CompanyName varchar(50) = 'Kiran Sales Pty Ltd t/a Lylax Bedding'
DECLARE @CompanyName varchar(60) = 'Kiran%20Sales%20Pty%20Ltd%20t%2Fa%20Lylax%20Bedding'
DECLARE @url varchar(500) = CONCAT('http://',@IP,':',@PortNumber,'/Report/Granite%20SO?CompanyName=',@CompanyName,'&UserName=',@User,'&password=',@Password,'&IDATETOUSE=ENTERED&IFROMDATE=Default%20Date&ITODATE=Default%20Date&IEXPANDDETAIL=Y&IINCLUDEZEROLINES=N&IINCLUDECOMPLETED=N&IINCLUDECANCELLED=N')

DECLARE @Documents TABLE(
	Number varchar(50)
)

DECLARE @Document varchar(50)

EXEC HTTP_GET_JSON @url, @HttpStatus OUT, @HttpStatusText OUT, @HttpResponseText OUT

INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
SELECT GETDATE(), @HttpResponseText, 'Omni_FetchNewSalesOrders'

IF @HttpStatus = 200
BEGIN
	INSERT INTO @Documents
	SELECT DISTINCT reference FROM
	OPENJSON((SELECT value FROM OPENJSON(@HttpResponseText)))
	WITH (reference varchar(50))

	IF EXISTS(SELECT TOP 1 Number FROM @Documents)
	BEGIN
		DECLARE c CURSOR LOCAL FAST_FORWARD FOR
		SELECT Number 
		FROM @Documents docs
		WHERE NOT EXISTS(SELECT ID FROM Document WHERE Document.Number = docs.Number) -- temporarily added to insert new docs only

		OPEN c

		FETCH NEXT FROM c INTO @Document

		WHILE @@FETCH_STATUS = 0
		BEGIN
			WAITFOR DELAY '00:00:15'
			--IF NOT EXISTS(SELECT ID FROM Document WHERE Number = @Document)
			--BEGIN
				--SELECT @Document 
				EXEC Omni_SalesOrderSync @Document
			--END
			
			FETCH NEXT FROM c INTO @Document
		END

		CLOSE c
		DEALLOCATE c
	END
END


GO


