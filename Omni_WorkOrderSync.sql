USE [GraniteDatabase]
GO
/****** Object:  StoredProcedure [dbo].[Omni_WorkOrderSync]    Script Date: 07/02/2025 05:57:53 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[Omni_WorkOrderSync]
	@DocumentNumber varchar(30)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;


	DECLARE @Document TABLE (
	JOBNO varchar(30),
	OJOBDESC varchar(100),
	DATECREATED datetime,
	DATELASTMODIFIED datetime,
	ISACTIVE bit,
	WAREHOUSE varchar(30),
	FGCODE varchar(25),
	FGQTY decimal(19,5),
	DELIVERYDETAILS varchar(50)
	)

    DECLARE @DocumentLines TABLE (
	JOBNO varchar(30),
	ITEMCODE varchar(25),
	PARENTID varchar(25),
	SEQUENCENO varchar(10),
	WAREHOUSECODE varchar(10),
	QUANTITYREQUIRED decimal(19,5),
	RECIPEYIELD decimal(19,5),
	JOBQUANTITY decimal(19,5),
	ACTUALQTY decimal(19,5),
	UOM varchar(4)
	)

	DECLARE @AuditUser varchar(20) = 'INTEGRATION'
	DECLARE @AuditDate datetime = getdate()
	DECLARE @Document_id bigint
	DECLARE @sql varchar(max)
	DECLARE @FGCODE varchar(30)
	DECLARE @FGQTY decimal(19,5)
	DECLARE @MasterItemCode varchar(50)

	DECLARE @HttpStatus VARCHAR(60);
	DECLARE @HttpStatusText VARCHAR(60);
	DECLARE @HttpResponseText VARCHAR(max);
	
	DECLARE @IP varchar(20) = '172.30.5.4'
	DECLARE @PortNumber varchar(10) = '51968'
	DECLARE @User varchar(20) = 'automate'
	DECLARE @Password varchar(20) = 'auto123'
	--DECLARE @CompanyName varchar(50) = 'Kiran Sales Pty Ltd t/a Lylax Bedding'
	DECLARE @CompanyName varchar(60) = 'Kiran%20Sales%20Pty%20Ltd%20t%2Fa%20Lylax%20Bedding'
	DECLARE @url varchar(500) 
	SELECT @url = CONCAT('http://',@IP,':',@PortNumber,'/Job/',@DocumentNumber,'?UserName=',@User,'&Password=',@Password,'&CompanyName=',@CompanyName)

	EXEC dbo.HTTP_GET_JSON @url, @HttpStatus OUTPUT, @HttpStatusText OUTPUT, @HttpResponseText OUTPUT

	IF @HttpStatus = 200
	BEGIN
		INSERT INTO @Document
		SELECT * 
		FROM OPENJSON(@HttpResponseText, '$.job')
		WITH 
			(job_no varchar(50),
			job_description varchar(500),
			date_created datetime,
			date_last_modified datetime,
			active bit,
			warehouse_code varchar(10),
			stock_code varchar(50),
			quantity decimal(19,5),
			delivery_details varchar(50))

		SELECT @FGCODE = FGCODE, @FGQTY = FGQTY
		FROM @Document

		IF NOT EXISTS(SELECT ID FROM Document WHERE Number = @DocumentNumber)
		BEGIN
			INSERT INTO Document (Number, TradingPartnerCode,Description, CreateDate, Status, ERPLocation, [Type], AuditDate, AuditUser)

			SELECT JOBNO, DELIVERYDETAILS, OJOBDESC, DATECREATED, CASE WHEN ISACTIVE = 1 THEN 'RELEASED' ELSE 'COMPLETE' END, WAREHOUSE, 'WORKORDER',DATELASTMODIFIED, 'INTEGRATION'
			FROM @Document
		END
		ELSE
		BEGIN
			UPDATE Document
			SET --[Status] = CASE WHEN Omni.ISACTIVE = 1 THEN 'RELEASED' ELSE 'COMPLETE' END,
				TradingPartnerCode = DELIVERYDETAILS,
				AuditDate = GETDATE(),
				ERPLocation = Omni.WAREHOUSE
			FROM @Document Omni
			WHERE Document.Number = Omni.JOBNO
		END

		SELECT @url = CONCAT('http://',@IP,':',@PortNumber,'/Stock%20Recipe/',@FGCODE,'?UserName=',@User,'&Password=',@Password,'&CompanyName=',@CompanyName)

		EXEC dbo.HTTP_GET_JSON @url, @HttpStatus OUTPUT, @HttpStatusText OUTPUT, @HttpResponseText OUTPUT

		IF @HttpStatus = 200
		BEGIN
			INSERT INTO @DocumentLines (ITEMCODE, ACTUALQTY)
			SELECT stock_code, (quantity_required / recipe_yield) * @FGQTY
			FROM OPENJSON(@HttpResponseText) 
			WITH (recipe_yield decimal(19,3) '$.stock_recipe.recipe_yield',
					recipe_lines nvarchar(max) '$.stock_recipe.recipe_lines' as json) as doc
			CROSS APPLY OPENJSON(doc.recipe_lines)
			WITH (stock_code varchar(50),
					quantity_required decimal(19,3))

			--DECLARE MasterItems CURSOR FOR
			--SELECT ITEMCODE 
			--FROM @DocumentLines

			--OPEN MasterItems
	
			--FETCH NEXT FROM MasterItems
			--INTO @MasterItemCode

			--WHILE @@FETCH_STATUS = 0
			--BEGIN

			--	EXEC Omni_MasterItemSyncSingle @MasterItemCode

			--	FETCH NEXT FROM MasterItems
			--	INTO @MasterItemCode

			--END

			--CLOSE MasterItems
			--DEALLOCATE MasterItems

			SELECT @Document_id = ID FROM Document WHERE Number = @DocumentNumber

			UPDATE DocumentDetail
			SET Qty = CASE WHEN ISNULL(ActionQty,0) <= Omni.ACTUALQTY THEN Omni.ACTUALQTY ELSE Qty END,
						FromLocation = (SELECT TOP 1 WAREHOUSE FROM @Document),
						Item_id = CASE WHEN ISNULL(ActionQty,0) = 0 THEN MasterItem.ID ELSE Item_id END,
						UOM = MasterItem.UOM,
						AuditDate = @AuditDate,
						AuditUser = @AuditUser
			FROM @DocumentLines Omni INNER JOIN
			MasterItem ON Omni.ITEMCODE = MasterItem.Code
			WHERE DocumentDetail.Document_id = @Document_id AND DocumentDetail.Item_id = MasterItem.ID

			UPDATE DocumentDetail
			SET ToLocation = Omni.WAREHOUSE
			FROM (SELECT TOP 1 WAREHOUSE FROM @Document) Omni
			WHERE Document_id = @Document_id AND LineNumber = '0' AND [Type] = 'OUTPUT'

			INSERT INTO DocumentDetail (LineNumber, Qty, ToLocation, Item_id, Document_id, Completed, [Type], AuditDate, AuditUser)
			SELECT TOP 1 '0', FGQTY, WAREHOUSE, MasterItem.ID, @Document_id, 0, 'OUTPUT', @AuditDate, @AuditUser
			FROM @Document Omni INNER JOIN
			MasterItem ON Omni.FGCODE = MasterItem.Code
			WHERE MasterItem.ID NOT IN (SELECT Item_id FROM DocumentDetail WHERE Document_id = @Document_id)

			INSERT INTO DocumentDetail (LineNumber, Qty, UOM, FromLocation, Item_id, Document_id, Completed, [Type], AuditDate, AuditUser)
			SELECT (SELECT MAX(CAST(LineNumber as int)) FROM DocumentDetail WHERE Document_id = @Document_id) + ROW_NUMBER() OVER(ORDER BY MasterItem.ID ASC), ACTUALQTY, Omni.UOM, (SELECT TOP 1 WAREHOUSE FROM @Document), 
			MasterItem.ID, @Document_id, 0, 'INPUT', @AuditDate, @AuditUser
			FROM @DocumentLines Omni INNER JOIN
			MasterItem ON Omni.ITEMCODE = MasterItem.Code
			WHERE MasterItem.ID NOT IN (SELECT Item_id FROM DocumentDetail WHERE Document_id = @Document_id)
		END
		ELSE
		BEGIN
			INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
			SELECT GETDATE(), @HttpResponseText, 'Omni_WorkOrderSync - Detail'
		END
	END
	ELSE
	BEGIN
		INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
		SELECT GETDATE(), @HttpResponseText, 'Omni_WorkOrderSync - Header'
	END
	   	  
END
