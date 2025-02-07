USE [GraniteDatabase]
GO
/****** Object:  StoredProcedure [dbo].[Omni_SalesOrderSync]    Script Date: 07/02/2025 05:00:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
ALTER PROCEDURE [dbo].[Omni_SalesOrderSync] 
	-- Add the parameters for the stored procedure here
	@DocumentNumber varchar(30)
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- Insert statements for procedure here

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

	SELECT @url = CONCAT('http://',@IP,':',@PortNumber,'/Sales%20Order/',@DocumentNumber,'?UserName=',@User,'&Password=',@Password,'&CompanyName=',@CompanyName)

	DECLARE @Document_id bigint
	DECLARE @MasterItemCode varchar(50)

	DECLARE @Document TABLE (
		REFNO varchar(15),
		ODBTRCDE varchar(30),
		ODBTRNME varchar(100),
		LINEWAREHOUSE varchar(4),
		DOCWAREHOUSE varchar(4),
		ORDERSTATUS varchar(30),
		STOCKCODE varchar(25),
		LINENUMBER int,
		UNITOFMEASURE varchar(5),
		ORDEREDQTY decimal(18, 5),
		LINEDESCRIPTION varchar(60),
		DUEDATE varchar(10),
		CUSTOMERBRANCHCODE varchar(10)
	)

	DECLARE @sql varchar(max)

	EXEC dbo.HTTP_GET_JSON @url, @HttpStatus OUTPUT, @HttpStatusText OUTPUT, @HttpResponseText OUTPUT

	INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
	SELECT GETDATE(), @HttpResponseText, CONCAT(@DocumentNumber, ' GET - Omni_SalesOrderSync')

	IF @HttpStatus = 200
	BEGIN
		INSERT INTO @Document
		SELECT @DocumentNumber, customer_account_code, customer_name, warehouse, warehouse_code, CASE WHEN [status] IN ('CANCELLED', 'COMPLETE') THEN UPPER([status]) ELSE 'RELEASED' END,
			stock_code, line_no, measure, ordered, description, due_date, customer_branch_code
		FROM OPENJSON(@HttpResponseText, '$.order')
		WITH (
			customer_account_code varchar(50),
			customer_name varchar(150),
			customer_branch_code varchar(10),
			document_date datetime,
			status varchar(50),
			warehouse_code varchar(10),
			due_date varchar(10),
			order_lines nvarchar(max) '$.order_lines' as json
		) doc
		CROSS APPLY OPENJSON(doc.order_lines)
		WITH (line_no int,
				warehouse varchar(10),
				measure varchar(10),
				stock_code varchar(50), 
				description varchar(150),
				ordered decimal(19,5)) lines

		DECLARE MasterItems CURSOR FOR
		SELECT STOCKCODE 
		FROM @Document

		OPEN MasterItems
	
		FETCH NEXT FROM MasterItems
		INTO @MasterItemCode

		WHILE @@FETCH_STATUS = 0
		BEGIN

			EXEC Omni_MasterItemSyncSingle @MasterItemCode

			FETCH NEXT FROM MasterItems
			INTO @MasterItemCode

		END

		CLOSE MasterItems
		DEALLOCATE MasterItems

		IF NOT EXISTS(SELECT ID FROM Document WHERE Number = @DocumentNumber)
		BEGIN
			INSERT INTO Document (Number, [Description], TradingPartnerCode, TradingPartnerDescription, CreateDate, AuditDate, AuditUser, [Status], [Type], ERPLocation, DueDate)
			SELECT TOP 1 @DocumentNumber, ODBTRCDE, ODBTRCDE, ODBTRNME, GETDATE(), GETDATE(), 'INTEGRATION', ORDERSTATUS, 'ORDER', DOCWAREHOUSE, DUEDATE
			FROM @Document
		END

		SELECT @Document_id = ID FROM Document WHERE Number = @DocumentNumber
	
		UPDATE Document
		SET [Description] = doc.ODBTRCDE,
			TradingPartnerCode = doc.ODBTRCDE,
			TradingPartnerDescription = doc.ODBTRNME,
			[Status] = ORDERSTATUS,
			AuditDate = GETDATE(),
			AuditUser = 'INTEGRATION',
			DueDate = doc.DUEDATE
		FROM (SELECT TOP 1 * FROM @Document) as doc
		WHERE Document.Number = @DocumentNumber

		DELETE FROM DocumentDetail
		WHERE ActionQty = 0 AND Document_id = @Document_id AND 
		CAST(LineNumber as int) NOT IN (SELECT LineNumber FROM @Document)

		--Insert new lines where line number not in document detail
		INSERT INTO DocumentDetail (LineNumber, Qty, UOM, Completed, Comment, Item_id, Document_id, AuditDate, AuditUser, FromLocation)
		SELECT LINENUMBER, ORDEREDQTY, a.UNITOFMEASURE, 0, LEFT(LINEDESCRIPTION, 50), MasterItem.ID, @Document_id, GETDATE(), 'INTEGRATION', CASE WHEN LINEWAREHOUSE = 'CPTM' THEN 'CPTB' ELSE LINEWAREHOUSE END
		FROM @Document a INNER JOIN MasterItem ON a.STOCKCODE collate Latin1_General_CI_AS = MasterItem.Code
		WHERE REFNO = @DocumentNumber AND a.LINENUMBER NOT IN (SELECT LineNumber FROM DocumentDetail WHERE Document_id = @Document_id)

		--Update existing lines that have not been actioned
		UPDATE a
		SET	a.UOM = UNITOFMEASURE, 
			Item_id = CASE WHEN ISNULL(a.ActionQty, 0) = 0 THEN MasterItem.ID ELSE Item_id END, 
			a.Qty = CASE WHEN ISNULL(a.ActionQty, 0) <= ORDEREDQTY THEN ORDEREDQTY ELSE a.Qty END, 
			a.Comment = LEFT(LINEDESCRIPTION,50),
			FromLocation = CASE WHEN ISNULL(a.ActionQty, 0) = 0 THEN CASE WHEN LINEWAREHOUSE = 'CPTM' THEN 'CPTB' ELSE LINEWAREHOUSE END ELSE FromLocation END, 
			AuditDate = GETDATE(), 
			AuditUser = 'INTEGRATION'
		FROM DocumentDetail a INNER JOIN 
		Document ON a.Document_id = Document.ID INNER JOIN
		@Document b ON Document.Number = b.REFNO collate Latin1_General_CI_AS AND CAST(a.LineNumber as int) = b.LINENUMBER INNER JOIN
		MasterItem ON b.STOCKCODE collate Latin1_General_CI_AS = MasterItem.Code
		WHERE Document.Number = @DocumentNumber AND ISNULL(a.ActionQty, 0) = 0

		--Fix multiple entries in case of change
		UPDATE DocumentDetail
		SET MultipleEntries = 1 
		WHERE Document_id = @Document_id AND Item_id IN (SELECT Item_id FROM DocumentDetail WHERE Document_id = @Document_id GROUP BY Item_id HAVING COUNT(ID) > 1)

		UPDATE DocumentDetail
		SET MultipleEntries = 0 
		WHERE Document_id = @Document_id AND Item_id NOT IN (SELECT Item_id FROM DocumentDetail WHERE Document_id = @Document_id GROUP BY Item_id HAVING COUNT(ID) > 1)

		DECLARE @JobNumber varchar(50)
		DECLARE @Number varchar(50)
		DECLARE @LineNumber varchar(50)
		DECLARE @Code varchar(50)
		DECLARE @Qty int
		DECLARE @FromLocation varchar(10)
		DECLARE @JSON varchar(max)
		DECLARE @CustomerName varchar(50)
		DECLARE @CustomerBranchCode varchar(50)
		DECLARE @CustomerCode varchar(50)
		DECLARE @DueDate varchar(10)

		SELECT TOP 1 @CustomerCode = ODBTRCDE, 
		@CustomerName = ODBTRNME, 
		@CustomerBranchCode = CUSTOMERBRANCHCODE
		FROM @Document

		DECLARE c CURSOR LOCAL FAST_FORWARD FOR
		SELECT Number, LineNumber, Code, Qty, FromLocation, DueDate
		FROM DocumentDetail INNER JOIN
		Document ON DocumentDetail.Document_id = Document.ID INNER JOIN
		MasterItem ON DocumentDetail.Item_id = MasterItem.ID
		WHERE Document_id = @Document_id
		  AND MasterItem.Category IN ('MATT', 'BASE')

		OPEN c 

		FETCH NEXT FROM c INTO @Number, @LineNumber, @Code, @Qty, @FromLocation, @DueDate

		WHILE @@FETCH_STATUS = 0
		BEGIN
			SELECT @JobNumber = CONCAT(@Number,'_',@LineNumber)

			SELECT @url = CONCAT('http://',@IP,':',@PortNumber,'/Job/',@JobNumber,'?UserName=',@User,'&password=',@Password,'&CompanyName=', @CompanyName)

			SELECT @JSON = (
				SELECT @JobNumber as 'job.job_no',
				@Code as 'job.job_description',
				'MAN' as 'job.job_category',
				@CustomerName as 'job.customer_name',
				@CustomerBranchCode as 'job.customer_branch_code',
				@CustomerCode as 'job.customer_account_code',
				@DueDate as 'job.progress_date_3',
				'Manufacture' as 'job.invoice_method',
				@Code as 'job.stock_code',
				@FromLocation as 'job.warehouse_code', 
				@Qty as 'job.quantity',
				CAST(1 as bit) as 'job.active'
				FOR JSON PATH, WITHOUT_ARRAY_WRAPPER	 
			)

			INSERT INTO Custom_DebugJSON
			SELECT GETDATE(), @JSON, 'Omni_SalesOrderSync - Job Create - JSON to PUT'

			EXEC HTTP_PUT_JSON @url, @JSON, @HttpStatus OUT, @HttpStatusText OUT, @HttpResponseText OUT
			INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
			SELECT GETDATE(), @HttpResponseText, 'Omni_SalesOrderSync - Job PUT response'

			IF @HttpStatus = 200
			BEGIN
				EXEC Omni_WorkOrderSync @JobNumber
			END

			FETCH NEXT FROM c INTO @Number, @LineNumber, @Code, @Qty, @FromLocation, @DueDate
		END

		CLOSE c
		DEALLOCATE c
	END
	
END
