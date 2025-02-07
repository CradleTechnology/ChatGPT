USE [GraniteDatabase]
GO
/****** Object:  StoredProcedure [dbo].[Omni_MasterItemSyncSingle]    Script Date: 07/02/2025 06:20:00 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		James Davidson
-- Create date: 2023-05-30
-- Description:	Sync all categories & master items from Omni
-- =============================================
ALTER   PROCEDURE [dbo].[Omni_MasterItemSyncSingle] 

	@ItemCode varchar(50)

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @HttpStatus VARCHAR(60)
	DECLARE @HttpStatusText VARCHAR(60)
	DECLARE @HttpResponseText VARCHAR(MAX)

	DECLARE @IP varchar(20) = '172.30.5.4'
	DECLARE @PortNumber varchar(10) = '51968'
	DECLARE @User varchar(20) = 'automate'
	DECLARE @Password varchar(20) = 'auto123'
	--DECLARE @CompanyName varchar(50) = 'Kiran Sales Pty Ltd t/a Lylax Bedding'
	DECLARE @CompanyName varchar(60) =  'Kiran%20Sales%20Pty%20Ltd%20t%2Fa%20Lylax%20Bedding'
	DECLARE @url varchar(500) 

	DECLARE @StockItem TABLE (
		stock_code varchar(50),
		stock_description varchar(150),
		measure varchar(20),
		active char,
		stock_category varchar(30),
		product_group varchar(30),
		id varchar(50)
	)

	DECLARE @MasterItem_id bigint

	SELECT @url = CONCAT('http://',@IP,':',@PortNumber,'/Stock%20Item/', @ItemCode,'?UserName=',@User,'&Password=',@Password,'&CompanyName=',@CompanyName)

	EXEC dbo.HTTP_GET_JSON @url, @HttpStatus OUTPUT, @HttpStatusText OUTPUT, @HttpResponseText OUTPUT
	
	IF @HttpStatus = 200
	BEGIN

		INSERT INTO @StockItem (stock_code, stock_description, measure, active, stock_category, product_group, id)
		SELECT stock_code, stock_description, measure, 
			   CASE active WHEN 'true' THEN 1 ELSE 0 END, 
			   stock_category, product_group, id
		FROM OPENJSON(@HttpResponseText, '$.stockitem')
			WITH (
				stock_code varchar(50) '$.stock_code',
				stock_description varchar(150) '$.stock_description',
				measure varchar(20) '$.measure',
				active varchar(10) '$.active',
				stock_category varchar(20) '$.stock_category',
				product_group varchar(30) '$.product_group',
				id varchar(50) '$.id'
			)

		IF EXISTS(SELECT ID FROM MasterItem WHERE Code = (SELECT stock_code FROM @StockItem))
		BEGIN

			UPDATE MasterItem 
			SET Code = stock_code,
				[Description] = stock_description,
				isActive = active,
				UOM =  measure,
				Category =  stock_category,
				[Type] = product_group
			FROM @StockItem Omni_StockItem
			WHERE MasterItem.Code = Omni_StockItem.stock_code

		END
		ELSE
		BEGIN

			INSERT INTO MasterItem(Code, FormattedCode, [Description], UOM, isActive, AuditDate, AuditUser, Category, [Type], ERPIdentification)
			SELECT stock_code, stock_code, stock_description, measure, active, GETDATE(), 'INTEGRATION', stock_category, product_group, id
			FROM @StockItem Omni_StockItem WHERE stock_code NOT IN (SELECT Code FROM MasterItem)

		END

	END
	ELSE
	BEGIN

		INSERT INTO Custom_DebugJSON (Date, JSON, Comment)
		SELECT GETDATE(), @HttpResponseText, 'Omni_MasterItemSyncSingle'

	END

END
