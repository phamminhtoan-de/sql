-- ==========================================================================================
-- ████████████████████████████████████████████████████████████████████████████████████████
-- PHẦN 4: DATA WAREHOUSE PIPELINE: STAGING → DIMENSION → FACT
-- Kiến trúc chuẩn: RAW → STAGING → DIMENSION → FACT
-- Áp dụng cho Project Olist E-Commerce
-- ████████████████████████████████████████████████████████████████████████████████████████
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 1]: THIẾT KẾ & NẠP TẦNG STAGING (STAGING LAYER)
-- ------------------------------------------------------------------------------------------

-- Câu 4.1.1:
-- Thiết kế bảng Staging đơn hàng `stg_orders` và viết câu lệnh nạp làm sạch từ bảng nguồn thô:
-- Chuẩn hóa trạng thái đơn, định dạng ngày giờ chuẩn ISO, và loại bỏ các bản ghi không hợp lệ.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.1.1 TẠI ĐÂY:

IF SCHEMA_ID('stg') IS NULL
    EXEC('CREATE SCHEMA stg;');
GO

IF OBJECT_ID('stg.stg_dw_orders', 'U') IS NULL
BEGIN
    CREATE TABLE stg.stg_dw_orders (
        order_id                      VARCHAR(50) PRIMARY KEY,
        customer_id                   VARCHAR(50) NOT NULL,
        order_status                  VARCHAR(50) NOT NULL,
        order_purchase_timestamp      DATETIME2   NOT NULL,
        order_approved_at             DATETIME2   NULL,
        order_delivered_carrier_date  DATETIME2   NULL,
        order_delivered_customer_date DATETIME2   NULL,
        order_estimated_delivery_date DATETIME2   NULL,
        staged_at                     DATETIME2   NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

TRUNCATE TABLE stg.stg_dw_orders;

WITH dedup_orders AS (
    SELECT
        TRIM(order_id)            AS order_id,
        TRIM(customer_id)         AS customer_id,
        LOWER(TRIM(order_status)) AS order_status,
        CAST(order_purchase_timestamp AS DATETIME2)      AS order_purchase_timestamp,
        CAST(order_approved_at AS DATETIME2)             AS order_approved_at,
        CAST(order_delivered_carrier_date AS DATETIME2)  AS order_delivered_carrier_date,
        CAST(order_delivered_customer_date AS DATETIME2) AS order_delivered_customer_date,
        CAST(order_estimated_delivery_date AS DATETIME2) AS order_estimated_delivery_date,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY order_purchase_timestamp DESC) AS rn
    FROM dbo.olist_orders_dataset
    WHERE order_id IS NOT NULL
      AND customer_id IS NOT NULL
      AND order_status IS NOT NULL
      AND order_purchase_timestamp IS NOT NULL
      AND (order_delivered_customer_date IS NULL OR order_delivered_customer_date >= order_purchase_timestamp)
)
INSERT INTO stg.stg_dw_orders (
    order_id, customer_id, order_status, order_purchase_timestamp,
    order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
)
SELECT
    order_id, customer_id, order_status, order_purchase_timestamp,
    order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
FROM dedup_orders
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nạp thẳng từ bảng thô vào Dimension/Fact mà không qua Staging làm sạch sẽ đưa cả đơn hàng bị NULL khóa,
--      trùng khóa chính hoặc ngày giao nhỏ hơn ngày đặt đi vào kho, gây gãy quá trình nạp Fact hoặc sai toàn bộ báo cáo.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Tầng Staging `stg.stg_dw_orders` đóng vai trò vùng đệm chuẩn hóa kiểu dữ liệu DATETIME2, chữ thường đồng nhất cho order_status
--      và chỉ chứa các đơn hàng hợp lệ, duy nhất theo order_id.


-- ------------------------------------------------------------------------------------------
-- Câu 4.1.2:
-- Thiết kế bảng Staging khách hàng `stg_customers` và viết câu lệnh nạp:
-- Chuẩn hóa tên thành phố, mã bang, mã bưu chính và khử trùng lặp đưa về 1 dòng cho mỗi khách hàng duy nhất.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.1.2 TẠI ĐÂY:

IF OBJECT_ID('stg.stg_dw_customers', 'U') IS NULL
BEGIN
    CREATE TABLE stg.stg_dw_customers (
        customer_unique_id VARCHAR(50) PRIMARY KEY,
        customer_zip_code  CHAR(5)     NOT NULL,
        zip_code_prefix    INT         NOT NULL,
        customer_city      NVARCHAR(200) NOT NULL,
        customer_state     CHAR(2)     NOT NULL,
        staged_at          DATETIME2   NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

TRUNCATE TABLE stg.stg_dw_customers;

WITH ranked_customers AS (
    SELECT
        TRIM(c.customer_unique_id) AS customer_unique_id,
        RIGHT('00000' + CAST(ISNULL(c.customer_zip_code_prefix, 0) AS VARCHAR(10)), 5) AS customer_zip_code,
        ISNULL(c.customer_zip_code_prefix, -1) AS zip_code_prefix,
        UPPER(TRIM(ISNULL(c.customer_city, N'UNKNOWN'))) AS customer_city,
        UPPER(TRIM(ISNULL(c.customer_state, 'XX')))     AS customer_state,
        ROW_NUMBER() OVER (
            PARTITION BY c.customer_unique_id
            ORDER BY o.order_purchase_timestamp DESC, c.customer_id DESC
        ) AS rn
    FROM dbo.olist_customers_dataset c
    LEFT JOIN dbo.olist_orders_dataset o
        ON c.customer_id = o.customer_id
    WHERE c.customer_unique_id IS NOT NULL
)
INSERT INTO stg.stg_dw_customers (
    customer_unique_id, customer_zip_code, zip_code_prefix, customer_city, customer_state
)
SELECT
    customer_unique_id, customer_zip_code, zip_code_prefix, customer_city, customer_state
FROM ranked_customers
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Một người dùng thật (`customer_unique_id`) mua nhiều đơn sẽ có nhiều dòng trong `olist_customers_dataset`;
--      nếu không gom về 1 dòng trước khi nạp Dimension sẽ gây trùng lặp hồ sơ khách hàng hoặc nổ dòng khi JOIN từ bảng Fact.
-- 2. Khi giải quyết xong thì như thế nào:
--    - `stg.stg_dw_customers` lưu đúng 1 dòng đại diện mới nhất cho mỗi `customer_unique_id`,
--      đã chuẩn hóa tên thành phố, mã bang 2 ký tự và mã bưu chính 5 chữ số.


-- ------------------------------------------------------------------------------------------
-- Câu 4.1.3:
-- Thiết kế bảng Staging sản phẩm `stg_products`:
-- Chuẩn hóa tên ngành hàng, quy đổi trọng lượng sang kg và kích thước sang m3, gán giá trị mặc định cho dữ liệu thiếu.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.1.3 TẠI ĐÂY:

IF OBJECT_ID('stg.stg_dw_products', 'U') IS NULL
BEGIN
    CREATE TABLE stg.stg_dw_products (
        product_id            VARCHAR(50) PRIMARY KEY,
        product_category_name NVARCHAR(200) NOT NULL,
        product_weight_kg     DECIMAL(10, 4) NOT NULL,
        product_volume_m3     DECIMAL(12, 6) NOT NULL,
        staged_at             DATETIME2 NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

TRUNCATE TABLE stg.stg_dw_products;

INSERT INTO stg.stg_dw_products (
    product_id, product_category_name, product_weight_kg, product_volume_m3
)
SELECT
    TRIM(product_id),
    LOWER(TRIM(COALESCE(NULLIF(product_category_name, N''), N'unknown'))),
    CAST(ISNULL(product_weight_g, 0) / 1000.0 AS DECIMAL(10, 4)) AS product_weight_kg,
    CAST(
        (ISNULL(CAST(product_length_cm AS BIGINT), 0)
         * ISNULL(CAST(product_height_cm AS BIGINT), 0)
         * ISNULL(CAST(product_width_cm  AS BIGINT), 0)) / 1000000.0
        AS DECIMAL(12, 6)
    ) AS product_volume_m3
FROM dbo.olist_products_dataset
WHERE product_id IS NOT NULL;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Sản phẩm bị NULL ngành hàng, thiếu thông số cân nặng/kích thước hoặc tính bằng gram/cm3 rời rạc
--      khiến phép nhân thể tích dễ bị NULL hóa toàn bộ biểu thức và báo cáo phân tích danh mục bị chia rời rạc.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ sản phẩm được quy đổi đồng nhất sang đơn vị chuẩn kho vận (kg và m3) và gán giá trị mặc định 'unknown' cho ngành hàng thiếu,
--      sẵn sàng cho tầng Dimension phân khúc sản phẩm.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 2]: XÂY DỰNG BẢNG CHIỀU KHÁCH HÀNG (DIM_CUSTOMER)
-- ------------------------------------------------------------------------------------------

-- Câu 4.2.1:
-- Thiết kế cấu trúc bảng `dim_customer` chuẩn Data Warehouse:
-- Bao gồm khóa đại diện tự tăng (`customer_key INT IDENTITY(1,1)` làm Primary Key),
-- khóa tự nhiên nghiệp vụ (`customer_unique_id`), và các thuộc tính địa bàn đã chuẩn hóa.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.2.1 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_dim_customer', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_dim_customer (
        customer_key       INT IDENTITY(1,1) PRIMARY KEY, -- Surrogate Key (Khóa đại diện gọn 4 bytes)
        customer_unique_id VARCHAR(50)   NOT NULL UNIQUE,   -- Natural / Business Key
        customer_zip_code  CHAR(5)       NOT NULL,
        customer_city      NVARCHAR(200) NOT NULL,
        customer_state     CHAR(2)       NOT NULL,
        created_at         DATETIME2     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at         DATETIME2     NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu dùng chuỗi VARCHAR(50) dài (UUID 32-50 ký tự) làm khóa ngoại trực tiếp trong bảng Fact hàng chục triệu dòng,
--      bảng Fact và các Index sẽ bị phình dung lượng gấp nhiều lần, JOIN chuỗi chậm và tốn rất nhiều RAM.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Khóa đại diện `customer_key INT IDENTITY(1,1)` chỉ tốn 4 bytes, tách biệt Data Warehouse khỏi thay đổi khóa ở hệ thống nguồn
--      và giúp mọi phép JOIN giữa Fact và Dim cực nhanh trên số nguyên.


-- ------------------------------------------------------------------------------------------
-- Câu 4.2.2:
-- Viết câu lệnh nạp dữ liệu từ `stg_customers` vào `dim_customer`:
-- Đảm bảo có thêm bản ghi đại diện mặc định mang khóa `customer_key = -1` ('Unknown Customer')
-- để dự phòng cho các đơn hàng mồ côi không tìm thấy thông tin khách.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.2.2 TẠI ĐÂY:

-- 1. Chèn bản ghi đại diện mặc định customer_key = -1 nếu chưa có
IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_customer WHERE customer_key = -1)
BEGIN
    SET IDENTITY_INSERT dbo.dw_dim_customer ON;

    INSERT INTO dbo.dw_dim_customer (
        customer_key, customer_unique_id, customer_zip_code, customer_city, customer_state
    )
    VALUES (-1, 'UNKNOWN', '00000', N'Unknown Customer', 'XX');

    SET IDENTITY_INSERT dbo.dw_dim_customer OFF;
END;

-- 2. Nạp các khách hàng mới từ tầng Staging (Guarded INSERT tránh trùng Business Key)
INSERT INTO dbo.dw_dim_customer (
    customer_unique_id, customer_zip_code, customer_city, customer_state
)
SELECT
    s.customer_unique_id,
    s.customer_zip_code,
    s.customer_city,
    s.customer_state
FROM stg.stg_dw_customers s
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.dw_dim_customer d
    WHERE d.customer_unique_id = s.customer_unique_id
);
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Khi bảng Fact có đơn hàng không tra được khách hàng (dữ liệu nguồn thiếu hoặc trễ), khóa ngoại sẽ bị NULL;
--      nếu người dùng chạy INNER JOIN với DimCustomer để làm báo cáo, các đơn hàng đó sẽ bị "rơi mất" gây thiếu hụt tổng doanh thu!
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bản ghi `customer_key = -1` ('Unknown Customer') đóng vai trò phao cứu sinh cho mọi đơn hàng mồ côi,
--      giúp 100% dòng Fact luôn có khóa ngoại hợp lệ (NOT NULL) và không bao giờ thất thoát doanh thu khi INNER JOIN.


-- ------------------------------------------------------------------------------------------
-- Câu 4.2.3:
-- Áp dụng cơ chế cập nhật thông tin địa chỉ mới nhất cho khách hàng trong bảng Dimension (SCD Type 1).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.2.3 TẠI ĐÂY:

UPDATE dim
SET
    dim.customer_zip_code = stg.customer_zip_code,
    dim.customer_city     = stg.customer_city,
    dim.customer_state    = stg.customer_state,
    dim.updated_at        = CURRENT_TIMESTAMP
FROM dbo.dw_dim_customer dim
INNER JOIN stg.stg_dw_customers stg
    ON dim.customer_unique_id = stg.customer_unique_id
WHERE dim.customer_key <> -1
  AND (
      dim.customer_zip_code <> stg.customer_zip_code
      OR dim.customer_city  <> stg.customer_city
      OR dim.customer_state <> stg.customer_state
  );
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Khi khách hàng chuyển chỗ ở sang thành phố/bang mới, bảng Dimension vẫn giữ mãi địa chỉ cũ lúc mới tạo tài khoản;
--      ngược lại nếu UPDATE mù không kiểm tra thay đổi sẽ ghi đè hàng chục nghìn dòng không đổi gây lãng phí I/O và hỏng dấu vết `updated_at`.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Áp dụng SCD Type 1 ghi đè trực tiếp thông tin mới nhất chỉ trên những khách hàng thực sự đổi địa chỉ (loại trừ dòng mặc định -1),
--      giữ Dimension gọn nhẹ và phản ánh đúng địa bàn hiện tại.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 3]: XÂY DỰNG DIMENSION SẢN PHẨM & ĐỊA ĐIỂM (DIM_PRODUCT & DIM_LOCATION)
-- ------------------------------------------------------------------------------------------

-- Câu 4.3.1:
-- Thiết kế và viết câu lệnh nạp dữ liệu cho bảng `dim_product`:
-- Tạo khóa đại diện `product_key`, lưu mã sản phẩm, ngành hàng, phân khúc trọng lượng và phân khúc thể tích.
-- Bổ sung bản ghi mặc định `product_key = -1` ('Unknown Product').
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.3.1 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_dim_product', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_dim_product (
        product_key           INT IDENTITY(1,1) PRIMARY KEY,
        product_id            VARCHAR(50)    NOT NULL UNIQUE,
        product_category_name NVARCHAR(200)  NOT NULL,
        product_weight_kg     DECIMAL(10, 4) NOT NULL,
        weight_tier           VARCHAR(20)    NOT NULL,
        product_volume_m3     DECIMAL(12, 6) NOT NULL,
        volume_tier           VARCHAR(20)    NOT NULL,
        updated_at            DATETIME2      NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_product WHERE product_key = -1)
BEGIN
    SET IDENTITY_INSERT dbo.dw_dim_product ON;

    INSERT INTO dbo.dw_dim_product (
        product_key, product_id, product_category_name, product_weight_kg, weight_tier, product_volume_m3, volume_tier
    )
    VALUES (-1, 'UNKNOWN', N'Unknown Product', 0, 'Unknown', 0, 'Unknown');

    SET IDENTITY_INSERT dbo.dw_dim_product OFF;
END;

MERGE INTO dbo.dw_dim_product AS tgt
USING (
    SELECT
        product_id,
        product_category_name,
        product_weight_kg,
        CASE
            WHEN product_weight_kg <= 0.5 THEN 'Light'
            WHEN product_weight_kg <= 5.0 THEN 'Medium'
            ELSE 'Heavy'
        END AS weight_tier,
        product_volume_m3,
        CASE
            WHEN product_volume_m3 <= 0.005 THEN 'Small Box'
            WHEN product_volume_m3 <= 0.050 THEN 'Medium Box'
            ELSE 'Large Box'
        END AS volume_tier
    FROM stg.stg_dw_products
) AS src
    ON tgt.product_id = src.product_id
WHEN MATCHED AND tgt.product_key <> -1 AND EXISTS (
    SELECT src.product_category_name, src.product_weight_kg, src.weight_tier, src.product_volume_m3, src.volume_tier
    EXCEPT
    SELECT tgt.product_category_name, tgt.product_weight_kg, tgt.weight_tier, tgt.product_volume_m3, tgt.volume_tier
) THEN
    UPDATE SET
        tgt.product_category_name = src.product_category_name,
        tgt.product_weight_kg     = src.product_weight_kg,
        tgt.weight_tier           = src.weight_tier,
        tgt.product_volume_m3     = src.product_volume_m3,
        tgt.volume_tier           = src.volume_tier,
        tgt.updated_at            = CURRENT_TIMESTAMP
WHEN NOT MATCHED BY TARGET THEN
    INSERT (product_id, product_category_name, product_weight_kg, weight_tier, product_volume_m3, volume_tier)
    VALUES (src.product_id, src.product_category_name, src.product_weight_kg, src.weight_tier, src.product_volume_m3, src.volume_tier);
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Không có Surrogate Key `product_key` và các phân khúc đóng gói sẵn (`weight_tier`, `volume_tier`),
--      bộ phận kho vận và phân tích phải liên tục tính CASE WHEN trên hàng trăm nghìn dòng bán ra, vừa chậm vừa dễ thiếu sản phẩm mồ côi.
-- 2. Khi giải quyết xong thì như thế nào:
--    - `dbo.dw_dim_product` có khóa số nguyên gọn nhẹ, phân khúc trọng lượng/thể tích nhất quán và bản ghi mặc định -1 sẵn sàng tra cứu cho bảng Fact.


-- ------------------------------------------------------------------------------------------
-- Câu 4.3.2:
-- Thiết kế và nạp bảng danh mục địa điểm `dim_location`:
-- Khử trùng lặp bảng Geolocation để tạo danh mục địa bàn duy nhất theo mã bưu chính kèm tọa độ trung bình đại diện.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.3.2 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_dim_location', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_dim_location (
        location_key     INT IDENTITY(1,1) PRIMARY KEY,
        zip_code_prefix  INT            NOT NULL UNIQUE,
        zip_code_5digit  CHAR(5)        NOT NULL,
        city             NVARCHAR(100)  NOT NULL,
        state            NVARCHAR(20)   NOT NULL,
        avg_latitude     DECIMAL(10, 6) NOT NULL,
        avg_longitude    DECIMAL(10, 6) NOT NULL
    );
END;
GO

WITH geo_clean AS (
    SELECT
        geolocation_zip_code_prefix AS zip_code_prefix,
        RIGHT('00000' + CAST(geolocation_zip_code_prefix AS VARCHAR(10)), 5) AS zip_code_5digit,
        UPPER(TRIM(MAX(geolocation_city)))  AS city,
        UPPER(TRIM(MAX(geolocation_state))) AS state,
        CAST(AVG(CAST(geolocation_lat AS FLOAT)) AS DECIMAL(10, 6)) AS avg_latitude,
        CAST(AVG(CAST(geolocation_lng AS FLOAT)) AS DECIMAL(10, 6)) AS avg_longitude
    FROM dbo.olist_geolocation_dataset
    WHERE geolocation_zip_code_prefix IS NOT NULL
    GROUP BY geolocation_zip_code_prefix
)
INSERT INTO dbo.dw_dim_location (
    zip_code_prefix, zip_code_5digit, city, state, avg_latitude, avg_longitude
)
SELECT
    g.zip_code_prefix, g.zip_code_5digit, g.city, g.state, g.avg_latitude, g.avg_longitude
FROM geo_clean g
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.dw_dim_location d WHERE d.zip_code_prefix = g.zip_code_prefix
);
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Bảng gốc `olist_geolocation_dataset` có tới 1 triệu dòng lặp tọa độ trên cùng 1 mã bưu chính;
--      nếu dùng trực tiếp làm Dimension sẽ không thể tạo khóa duy nhất và gây nổ dòng nghiêm trọng khi nối vào Fact.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ bảng Geolocation được nén gọn về đúng 1 dòng tọa độ trung tâm duy nhất cho mỗi mã bưu chính,
--      giúp vẽ bản đồ nhiệt (Heatmap) doanh thu theo vùng cực nhanh và chính xác.


-- ------------------------------------------------------------------------------------------
-- Câu 4.3.3:
-- Bổ sung bản ghi mặc định `location_key = -1` ('Unknown Location') vào bảng địa điểm.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.3.3 TẠI ĐÂY:

IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_location WHERE location_key = -1)
BEGIN
    SET IDENTITY_INSERT dbo.dw_dim_location ON;

    INSERT INTO dbo.dw_dim_location (
        location_key, zip_code_prefix, zip_code_5digit, city, state, avg_latitude, avg_longitude
    )
    VALUES (-1, -1, '00000', N'Unknown Location', N'XX', 0.0, 0.0);

    SET IDENTITY_INSERT dbo.dw_dim_location OFF;
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Một số mã bưu chính của khách hàng có thể không xuất hiện trong bảng Geolocation gốc;
--      khi nạp Fact mà không có dòng mặc định `-1`, các dòng đó sẽ mang `location_key = NULL` và bị rơi mất khi INNER JOIN với DimLocation.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Mọi mã bưu chính chưa có tọa độ đều trỏ an toàn về `location_key = -1` ('Unknown Location'),
--      giữ cột khóa ngoại NOT NULL và bảo toàn 100% số lượng giao dịch trong bảng Fact.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 4]: XÂY DỰNG BẢNG CHIỀU THỜI GIAN (DIM_DATE)
-- ------------------------------------------------------------------------------------------

-- Câu 4.4.1:
-- Thiết kế bảng chiều thời gian `dim_date` hoàn chỉnh:
-- Khóa chính `date_key INT` (dạng số nguyên YYYYMMDD), ngày chuẩn ISO, năm, quý, tháng, tuần trong năm,
-- tên thứ và cờ phân biệt ngày cuối tuần (`is_weekend`).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.4.1 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_dim_date', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_dim_date (
        date_key     INT          PRIMARY KEY, -- Dạng YYYYMMDD (vd: 20180115), -1 là Unknown
        full_date    DATE         NOT NULL,
        [year]       SMALLINT     NOT NULL,
        [quarter]    TINYINT      NOT NULL,
        [month]      TINYINT      NOT NULL,
        month_name   VARCHAR(20)  NOT NULL,
        week_of_year TINYINT      NOT NULL,
        day_of_month TINYINT      NOT NULL,
        day_name     VARCHAR(20)  NOT NULL,
        is_weekend   BIT          NOT NULL
    );
END;

IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_date WHERE date_key = -1)
BEGIN
    INSERT INTO dbo.dw_dim_date (
        date_key, full_date, [year], [quarter], [month], month_name, week_of_year, day_of_month, day_name, is_weekend
    )
    VALUES (-1, '1900-01-01', 1900, 1, 1, 'Unknown', 1, 1, 'Unknown', 0);
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu không có DimDate mà lọc trực tiếp bằng `YEAR(order_date) = 2018` trên bảng Fact hàng triệu dòng,
--      truy vấn sẽ bị Non-SARGable (mất Index Seek) và không thể nhóm linh hoạt theo Quý, Tuần, Cuối tuần.
-- 2. Khi giải quyết xong thì như thế nào:
--    - `date_key` dạng số nguyên YYYYMMDD vừa dễ đọc trực tiếp, vừa giúp lọc/JOIN SARGable qua khóa nguyên 4 bytes
--      và cung cấp đầy đủ thuộc tính lịch (Năm, Quý, Tháng, Tuần, Thứ, Cuối tuần) phục vụ cắt lớp BI ngay lập tức.


-- ------------------------------------------------------------------------------------------
-- Câu 4.4.2:
-- Viết câu lệnh SQL tự động sinh toàn bộ danh mục ngày tháng từ ngày 2016-01-01 đến 2020-12-31
-- để nạp sẵn dữ liệu cho bảng `dim_date`.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.4.2 TẠI ĐÂY:

WITH date_series AS (
    SELECT CAST('2016-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY, 1, dt)
    FROM date_series
    WHERE dt < '2020-12-31'
)
INSERT INTO dbo.dw_dim_date (
    date_key, full_date, [year], [quarter], [month], month_name, week_of_year, day_of_month, day_name, is_weekend
)
SELECT
    CONVERT(INT, CONVERT(VARCHAR(8), dt, 112)) AS date_key,
    dt                                         AS full_date,
    YEAR(dt)                                   AS [year],
    DATEPART(QUARTER, dt)                      AS [quarter],
    MONTH(dt)                                  AS [month],
    DATENAME(MONTH, dt)                        AS month_name,
    DATEPART(WEEK, dt)                         AS week_of_year,
    DAY(dt)                                    AS day_of_month,
    DATENAME(WEEKDAY, dt)                      AS day_name,
    CASE WHEN DATEPART(WEEKDAY, dt) IN (1, 7) AND @@DATEFIRST = 7 THEN 1
         WHEN DATEPART(WEEKDAY, dt) IN (6, 7) AND @@DATEFIRST = 1 THEN 1
         WHEN DATENAME(WEEKDAY, dt) IN ('Saturday', 'Sunday') THEN 1
         ELSE 0
    END AS is_weekend
FROM date_series d
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.dw_dim_date existing WHERE existing.date_key = CONVERT(INT, CONVERT(VARCHAR(8), d.dt, 112))
)
OPTION (MAXRECURSION 0); -- Bắt buộc vì mặc định SQL Server chỉ cho đệ quy tối đa 100 bước!
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu chỉ lấy ngày có đơn hàng từ bảng giao dịch, những ngày không có đơn sẽ bị khuyết trên biểu đồ xu hướng (Time Series);
--      nếu quên OPTION (MAXRECURSION 0), Recursive CTE sẽ chết ngay ở ngày thứ 101 với lỗi "maximum recursion 100 has been exhausted".
-- 2. Khi giải quyết xong thì như thế nào:
--    - Sinh đầy đủ liên tục 1,827 ngày (2016-2020) không đứt quãng và xử lý cờ cuối tuần độc lập với cài đặt `@@DATEFIRST` của server.


-- ------------------------------------------------------------------------------------------
-- Câu 4.4.3:
-- Viết câu lệnh tra cứu (Lookup) chuyển đổi từ mốc thời gian timestamp của đơn hàng
-- sang khóa ngoại `date_key` tương ứng trong bảng `dim_date`.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.4.3 TẠI ĐÂY:

SELECT TOP (100)
    o.order_id,
    o.order_purchase_timestamp,
    ISNULL(d_purchase.date_key, -1) AS purchase_date_key,
    ISNULL(d_delivered.date_key, -1) AS delivered_date_key,
    d_purchase.day_name,
    d_purchase.is_weekend
FROM stg.stg_dw_orders o
LEFT JOIN dbo.dw_dim_date d_purchase
    ON d_purchase.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_purchase_timestamp, 112))
LEFT JOIN dbo.dw_dim_date d_delivered
    ON d_delivered.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_delivered_customer_date, 112));
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nối trực tiếp bằng `CAST(order_purchase_timestamp AS DATE) = d.full_date` không có Index trên `full_date` hoặc bỏ qua giá trị NULL
--      sẽ làm phép tra cứu chậm hơn nhiều và tạo ra khóa ngoại NULL khi đơn chưa giao (`order_delivered_customer_date IS NULL`).
-- 2. Khi giải quyết xong thì như thế nào:
--    - Chuyển đổi mốc thời gian về đúng số nguyên YYYYMMDD để khớp trực tiếp vào Primary Key (`date_key`) của `dw_dim_date` (Index Seek)
--      và gán an toàn `-1` cho các mốc thời gian chưa phát sinh.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 5]: XÂY DỰNG BẢNG FACT BÁN HÀNG CHI TIẾT (FACT_SALES)
-- ------------------------------------------------------------------------------------------

-- Câu 4.5.1:
-- Xác định Grain hạt nhân của bảng Fact:
-- Thiết kế bảng `fact_sales` ở cấp độ: 1 dòng tương ứng với 1 mặt hàng bán ra trong đơn hàng (`order_id, order_item_id`).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.5.1 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_fact_sales', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_fact_sales (
        -- Composite Natural Key (xác định đúng Grain: 1 dòng / 1 mặt hàng trong đơn)
        order_id           VARCHAR(50)    NOT NULL,
        order_item_id      INT            NOT NULL,
        -- Dimension Surrogate Keys (bắt buộc NOT NULL, mặc định -1 nếu mồ côi)
        customer_key       INT            NOT NULL,
        product_key        INT            NOT NULL,
        location_key       INT            NOT NULL,
        purchase_date_key  INT            NOT NULL,
        order_status       VARCHAR(50)    NOT NULL,
        -- Additive Measures
        quantity           INT            NOT NULL DEFAULT 1,
        unit_price         DECIMAL(18, 2) NOT NULL,
        freight_value      DECIMAL(18, 2) NOT NULL,
        total_item_amount  DECIMAL(18, 2) NOT NULL,
        loaded_at          DATETIME2      NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT PK_DW_Fact_Sales PRIMARY KEY CLUSTERED (order_id, order_item_id)
    );
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Thiết kế Fact không xác định rõ Grain (trộn lẫn cả cấp đơn hàng và cấp mặt hàng vào 1 bảng hoặc thiếu khóa chính ghép)
--      sẽ làm doanh thu sản phẩm bị cộng lặp nhiều lần hoặc không phân tích chi tiết được tới từng SKU.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bảng `dbo.dw_fact_sales` cố định rõ hạt nhân `(order_id, order_item_id)` kèm toàn bộ Surrogate Keys gọn nhẹ (4 bytes/khóa)
--      và các chỉ số tài chính thuần túy phục vụ phân tích chi tiết tới từng mặt hàng.


-- ------------------------------------------------------------------------------------------
-- Câu 4.5.2:
-- Viết câu lệnh nạp dữ liệu vào `fact_sales` thực hiện tra cứu khóa ngoại (Dimension Key Lookup):
-- Nối dữ liệu mặt hàng với các bảng Dimension (`DimCustomer`, `DimProduct`, `DimLocation`, `DimDate`)
-- để lấy các Surrogate Key tương ứng (gán khóa -1 nếu không tìm thấy Dimension khớp).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.5.2 TẠI ĐÂY:

-- Nạp khóa ngoại Dimension Lookup (chỉ nạp các dòng chưa có trong Fact để đảm bảo Idempotent)
INSERT INTO dbo.dw_fact_sales (
    order_id, order_item_id, customer_key, product_key, location_key, purchase_date_key,
    order_status, quantity, unit_price, freight_value, total_item_amount
)
SELECT
    oi.order_id,
    oi.order_item_id,
    ISNULL(dc.customer_key, -1) AS customer_key,
    ISNULL(dp.product_key, -1)  AS product_key,
    ISNULL(dl.location_key, -1) AS location_key,
    ISNULL(dd.date_key, -1)     AS purchase_date_key,
    o.order_status,
    1                           AS quantity,
    CAST(ISNULL(oi.price, 0) AS DECIMAL(18, 2))                              AS unit_price,
    CAST(ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2))                      AS freight_value,
    CAST(ISNULL(oi.price, 0) + ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2)) AS total_item_amount
FROM dbo.olist_order_items_dataset oi
INNER JOIN stg.stg_dw_orders o
    ON oi.order_id = o.order_id
LEFT JOIN dbo.olist_customers_dataset raw_c
    ON o.customer_id = raw_c.customer_id
LEFT JOIN dbo.dw_dim_customer dc
    ON raw_c.customer_unique_id = dc.customer_unique_id
LEFT JOIN dbo.dw_dim_product dp
    ON oi.product_id = dp.product_id
LEFT JOIN dbo.dw_dim_location dl
    ON raw_c.customer_zip_code_prefix = dl.zip_code_prefix
LEFT JOIN dbo.dw_dim_date dd
    ON dd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_purchase_timestamp, 112))
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.dw_fact_sales f
    WHERE f.order_id = oi.order_id AND f.order_item_id = oi.order_item_id
);
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu dùng INNER JOIN khi tra cứu các bảng Dimension, bất kỳ mặt hàng nào thiếu thông tin khách hàng/sản phẩm/địa điểm
--      sẽ bị loại âm thầm khỏi bảng Fact làm tổng doanh thu bị hụt; ngược lại nếu LEFT JOIN mà không bọc `ISNULL(..., -1)` sẽ sinh ra khóa ngoại NULL.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Quá trình Dimension Key Lookup kết hợp `LEFT JOIN` + `ISNULL(key, -1)` giữ lại toàn vẹn 100% mặt hàng bán ra
--      và gắn đúng các Surrogate Key chuẩn Star Schema.


-- ------------------------------------------------------------------------------------------
-- Câu 4.5.3:
-- Nạp các chỉ số tài chính cộng dồn được (Additive Measures) vào `fact_sales`:
-- Số lượng, đơn giá, tiền cước vận chuyển và tổng giá trị thanh toán của từng mặt hàng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.5.3 TẠI ĐÂY:

-- Đồng bộ/cập nhật lại các Additive Measures khi đơn giá hoặc phí vận chuyển có điều chỉnh từ nguồn
UPDATE f
SET
    f.order_status      = o.order_status,
    f.unit_price        = CAST(ISNULL(oi.price, 0) AS DECIMAL(18, 2)),
    f.freight_value     = CAST(ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2)),
    f.total_item_amount = CAST(ISNULL(oi.price, 0) + ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2)),
    f.loaded_at         = CURRENT_TIMESTAMP
FROM dbo.dw_fact_sales f
INNER JOIN dbo.olist_order_items_dataset oi
    ON f.order_id = oi.order_id AND f.order_item_id = oi.order_item_id
INNER JOIN stg.stg_dw_orders o
    ON f.order_id = o.order_id
WHERE f.unit_price    <> CAST(ISNULL(oi.price, 0) AS DECIMAL(18, 2))
   OR f.freight_value <> CAST(ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2))
   OR f.order_status  <> o.order_status;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu lưu các chỉ số bán-cộng-dồn (như tỷ lệ %, đơn giá trung bình) thay vì các Additive Measures gốc (`quantity`, `unit_price`, `freight_value`, `total_item_amount`),
--      hoặc không đồng bộ khi giá/cước điều chỉnh, các phép `SUM()` ở tầng BI theo ngày/tháng/ngành hàng sẽ cho ra kết quả sai toán học.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bảng Fact lưu chuẩn các chỉ số cộng dồn tuyến tính (Additive Measures) và chỉ cập nhật các dòng thực sự đổi số liệu tài chính,
--      bảo đảm mọi phép tổng hợp đa chiều ở Power BI/Tableau đều chính xác.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 6]: XÂY DỰNG BẢNG FACT ĐƠN HÀNG TỔNG QUÁT (FACT_ORDERS)
-- ------------------------------------------------------------------------------------------

-- Câu 4.6.1:
-- Thiết kế bảng Fact thứ hai `fact_orders` ở cấp độ Grain: 1 dòng tương ứng với 1 đơn hàng nguyên vẹn (`order_id`).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.6.1 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_fact_orders', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_fact_orders (
        order_id             VARCHAR(50)    PRIMARY KEY CLUSTERED, -- Grain: 1 dòng / 1 đơn hàng
        customer_key         INT            NOT NULL,
        location_key         INT            NOT NULL,
        purchase_date_key    INT            NOT NULL,
        delivered_date_key   INT            NOT NULL,
        order_status         VARCHAR(50)    NOT NULL,
        primary_payment_type NVARCHAR(100)  NOT NULL,
        item_count           INT            NOT NULL,
        total_item_price     DECIMAL(18, 2) NOT NULL,
        total_freight_value  DECIMAL(18, 2) NOT NULL,
        total_order_amount   DECIMAL(18, 2) NOT NULL,
        total_payment_value  DECIMAL(18, 2) NOT NULL,
        delivery_days        INT            NULL,
        is_on_time_sla       BIT            NOT NULL,
        loaded_at            DATETIME2      NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu mọi báo cáo cấp đơn hàng (AOV, tỷ lệ giao đúng hạn SLA, tổng tiền thanh toán) đều phải `COUNT(DISTINCT order_id)` trên bảng chi tiết mặt hàng,
--      truy vấn sẽ chậm vì phải quét số dòng lớn hơn và rất dễ bị nhân bản giá trị thanh toán cấp đơn hàng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bảng `dbo.dw_fact_orders` chuyên biệt hóa ở cấp độ đơn hàng giúp mọi truy vấn KPI đơn hàng chạy nhanh gọn,
--      không cần `DISTINCT` hay chia tỷ lệ thanh toán phức tạp.


-- ------------------------------------------------------------------------------------------
-- Câu 4.6.2:
-- Nạp dữ liệu vào `fact_orders` từ tầng Staging:
-- Tính tổng số món hàng, tổng tiền hàng, tổng cước phí, hình thức thanh toán chính,
-- và số ngày hoàn tất giao hàng của từng đơn.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.6.2 TẠI ĐÂY:

WITH item_summary AS (
    SELECT
        order_id,
        COUNT(*)                           AS item_count,
        CAST(SUM(price) AS DECIMAL(18, 2))         AS total_item_price,
        CAST(SUM(freight_value) AS DECIMAL(18, 2)) AS total_freight_value
    FROM dbo.olist_order_items_dataset
    GROUP BY order_id
),
payment_ranked AS (
    SELECT
        order_id,
        payment_type,
        SUM(payment_value) AS type_amount,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY SUM(payment_value) DESC, MIN(payment_sequential) ASC) AS rn
    FROM dbo.olist_order_payments_dataset
    GROUP BY order_id, payment_type
),
payment_summary AS (
    SELECT
        p.order_id,
        CAST(SUM(p.payment_value) AS DECIMAL(18, 2)) AS total_payment_value,
        MAX(CASE WHEN pr.rn = 1 THEN pr.payment_type END) AS primary_payment_type
    FROM dbo.olist_order_payments_dataset p
    LEFT JOIN payment_ranked pr
        ON p.order_id = pr.order_id AND pr.rn = 1
    GROUP BY p.order_id
)
MERGE INTO dbo.dw_fact_orders AS tgt
USING (
    SELECT
        o.order_id,
        ISNULL(dc.customer_key, -1) AS customer_key,
        ISNULL(dl.location_key, -1) AS location_key,
        ISNULL(dpd.date_key, -1)    AS purchase_date_key,
        ISNULL(ddd.date_key, -1)    AS delivered_date_key,
        o.order_status,
        ISNULL(ps.primary_payment_type, N'unknown') AS primary_payment_type,
        ISNULL(its.item_count, 0)                   AS item_count,
        ISNULL(its.total_item_price, 0)             AS total_item_price,
        ISNULL(its.total_freight_value, 0)          AS total_freight_value,
        CAST(ISNULL(its.total_item_price, 0) + ISNULL(its.total_freight_value, 0) AS DECIMAL(18, 2)) AS total_order_amount,
        ISNULL(ps.total_payment_value, 0)           AS total_payment_value,
        CASE
            WHEN o.order_delivered_customer_date IS NOT NULL
                THEN DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date)
            ELSE NULL
        END AS delivery_days,
        CASE
            WHEN o.order_delivered_customer_date IS NOT NULL
             AND CAST(o.order_delivered_customer_date AS DATE) <= CAST(o.order_estimated_delivery_date AS DATE) THEN 1
            ELSE 0
        END AS is_on_time_sla
    FROM stg.stg_dw_orders o
    LEFT JOIN dbo.olist_customers_dataset raw_c
        ON o.customer_id = raw_c.customer_id
    LEFT JOIN dbo.dw_dim_customer dc
        ON raw_c.customer_unique_id = dc.customer_unique_id
    LEFT JOIN dbo.dw_dim_location dl
        ON raw_c.customer_zip_code_prefix = dl.zip_code_prefix
    LEFT JOIN dbo.dw_dim_date dpd
        ON dpd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_purchase_timestamp, 112))
    LEFT JOIN dbo.dw_dim_date ddd
        ON ddd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_delivered_customer_date, 112))
    LEFT JOIN item_summary its
        ON o.order_id = its.order_id
    LEFT JOIN payment_summary ps
        ON o.order_id = ps.order_id
) AS src
    ON tgt.order_id = src.order_id
WHEN MATCHED AND EXISTS (
    SELECT src.order_status, src.delivered_date_key, src.total_order_amount, src.total_payment_value, src.delivery_days, src.is_on_time_sla
    EXCEPT
    SELECT tgt.order_status, tgt.delivered_date_key, tgt.total_order_amount, tgt.total_payment_value, tgt.delivery_days, tgt.is_on_time_sla
) THEN
    UPDATE SET
        tgt.order_status         = src.order_status,
        tgt.delivered_date_key   = src.delivered_date_key,
        tgt.primary_payment_type = src.primary_payment_type,
        tgt.item_count           = src.item_count,
        tgt.total_item_price     = src.total_item_price,
        tgt.total_freight_value  = src.total_freight_value,
        tgt.total_order_amount   = src.total_order_amount,
        tgt.total_payment_value  = src.total_payment_value,
        tgt.delivery_days        = src.delivery_days,
        tgt.is_on_time_sla       = src.is_on_time_sla,
        tgt.loaded_at            = CURRENT_TIMESTAMP
WHEN NOT MATCHED BY TARGET THEN
    INSERT (
        order_id, customer_key, location_key, purchase_date_key, delivered_date_key,
        order_status, primary_payment_type, item_count, total_item_price, total_freight_value,
        total_order_amount, total_payment_value, delivery_days, is_on_time_sla
    )
    VALUES (
        src.order_id, src.customer_key, src.location_key, src.purchase_date_key, src.delivered_date_key,
        src.order_status, src.primary_payment_type, src.item_count, src.total_item_price, src.total_freight_value,
        src.total_order_amount, src.total_payment_value, src.delivery_days, src.is_on_time_sla
    );
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu ghép thẳng 2 bảng con `olist_order_items_dataset` và `olist_order_payments_dataset` trước khi GROUP BY,
--      số liệu tổng tiền hàng và tổng thanh toán của đơn sẽ bị nhân bội sai lệch nghiêm trọng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Tách riêng bước tổng hợp Items và Payments theo `order_id` trong CTE trước khi nạp Idempotent vào `dw_fact_orders`,
--      đảm bảo mỗi đơn hàng có đầy đủ phương thức thanh toán chính (trả tiền nhiều nhất), số ngày giao và trạng thái SLA chuẩn xác.


-- ------------------------------------------------------------------------------------------
-- Câu 4.6.3:
-- Đối soát tính toàn vẹn giữa hai bảng Fact:
-- So sánh tổng doanh thu tính từ `fact_sales` (cấp mặt hàng) và `fact_orders` (cấp đơn hàng)
-- để đảm bảo hai bảng Fact hoàn toàn khớp nhau về số liệu tài chính.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.6.3 TẠI ĐÂY:

WITH sales_tot AS (
    SELECT
        COUNT(DISTINCT order_id)     AS sales_orders_cnt,
        ISNULL(SUM(unit_price), 0)   AS sales_item_revenue,
        ISNULL(SUM(freight_value), 0) AS sales_freight,
        ISNULL(SUM(total_item_amount), 0) AS sales_total_amount
    FROM dbo.dw_fact_sales
),
orders_tot AS (
    SELECT
        COUNT(DISTINCT order_id)         AS orders_cnt_with_items,
        ISNULL(SUM(total_item_price), 0) AS orders_item_revenue,
        ISNULL(SUM(total_freight_value), 0) AS orders_freight,
        ISNULL(SUM(total_order_amount), 0)  AS orders_total_amount
    FROM dbo.dw_fact_orders
    WHERE item_count > 0
)
SELECT
    s.sales_orders_cnt,
    o.orders_cnt_with_items,
    s.sales_item_revenue,
    o.orders_item_revenue,
    (s.sales_total_amount - o.orders_total_amount) AS variance_amount,
    CASE
        WHEN s.sales_item_revenue = o.orders_item_revenue
         AND s.sales_freight = o.orders_freight
         AND s.sales_orders_cnt = o.orders_cnt_with_items
        THEN N'PASS: Hai bảng Fact khớp 100% số liệu tài chính'
        ELSE N'FAIL: Phát hiện lệch doanh thu giữa Fact_Sales và Fact_Orders!'
    END AS cross_fact_reconciliation
FROM sales_tot s
CROSS JOIN orders_tot o;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Báo cáo chi tiết sản phẩm lấy từ `Fact_Sales` lại ra con số tổng doanh thu khác với báo cáo tổng hợp từ `Fact_Orders`,
--      làm ban lãnh đạo mất niềm tin vào tính chính xác của toàn bộ Data Warehouse.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bước Cross-Fact Reconciliation kiểm chứng sự khớp tuyệt đối giữa hai bảng Fact ở 2 cấp Grain khác nhau,
--      chặn đứng rủi ro lệch số trước khi công bố báo cáo ra ngoài.



-- ------------------------------------------------------------------------------------------
-- [P4 - NGÀY 7]: ĐIỀU PHỐI TOÀN BỘ QUY TRÌNH DATA WAREHOUSE (END-TO-END ORCHESTRATION)
-- ------------------------------------------------------------------------------------------

-- Câu 4.7.1:
-- Xây dựng kịch bản điều phối thực thi trọn vẹn theo đúng trình tự phụ thuộc:
-- Bước 1: Nạp Staging -> Bước 2: Nạp các Dimension -> Bước 3: Nạp các Fact Table.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.7.1 TẠI ĐÂY:

-- Kịch bản điều phối chạy tuần tự theo DAG phụ thuộc:
--   [1. STAGING] -> [2. DIMENSIONS (song song/tuần tự)] -> [3. FACTS] -> [4. RECONCILIATION]
SET XACT_ABORT ON;

BEGIN TRY
    PRINT N'=== BƯỚC 1: Kiểm tra dữ liệu Staging đã sẵn sàng ===';
    IF (SELECT COUNT(*) FROM stg.stg_dw_orders) = 0
        THROW 50001, N'Lỗi phụ thuộc: Tầng Staging stg.stg_dw_orders đang trống!', 1;

    PRINT N'=== BƯỚC 2: Kiểm tra các Dimension đã có bản ghi mặc định -1 ===';
    IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_customer WHERE customer_key = -1)
    OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_product  WHERE product_key  = -1)
    OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_location WHERE location_key = -1)
    OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_date     WHERE date_key     = -1)
        THROW 50002, N'Lỗi phụ thuộc: Thiếu bản ghi Unknown (-1) trong Dimension!', 1;

    PRINT N'=== BƯỚC 3: Toàn bộ tầng Staging & Dimension hợp lệ -> sẵn sàng nạp Fact Tables ===';
    SELECT
        (SELECT COUNT(*) FROM stg.stg_dw_orders)   AS stg_orders_rows,
        (SELECT COUNT(*) FROM dbo.dw_dim_customer) AS dim_customer_rows,
        (SELECT COUNT(*) FROM dbo.dw_dim_product)  AS dim_product_rows,
        (SELECT COUNT(*) FROM dbo.dw_dim_location) AS dim_location_rows,
        (SELECT COUNT(*) FROM dbo.dw_dim_date)     AS dim_date_rows,
        (SELECT COUNT(*) FROM dbo.dw_fact_sales)   AS fact_sales_rows,
        (SELECT COUNT(*) FROM dbo.dw_fact_orders)  AS fact_orders_rows;
END TRY
BEGIN CATCH
    THROW;
END CATCH;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu chạy nạp bảng Fact trước khi bảng Dimension cập nhật xong khách hàng/sản phẩm mới,
--      toàn bộ giao dịch mới trong ngày sẽ bị gắn nhầm sang khóa `-1` ('Unknown') dù thông tin khách hàng thực tế có tồn tại ở nguồn!
-- 2. Khi giải quyết xong thì như thế nào:
--    - Thứ tự phụ thuộc Staging -> Dimension -> Fact được kiểm soát chặt chẽ bằng các điểm chốt kiểm tra (Dependency Gates),
--      ngăn chặn nạp sai thứ tự và bảo đảm tính nhất quán cho toàn kho.


-- ------------------------------------------------------------------------------------------
-- Câu 4.7.2:
-- Bổ sung các bài kiểm tra toàn vẹn tự động sau khi nạp kho (DW Quality Assertions):
-- Kiểm tra không có bất kỳ dòng Fact nào mang khóa ngoại bị NULL (phải trỏ tới khóa hợp lệ hoặc khóa -1).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.7.2 TẠI ĐÂY:

WITH dw_assertions AS (
    -- Kiểm tra 1: Không có Surrogate Key nào bị NULL trong dw_fact_sales
    SELECT
        'Fact_Sales_No_Null_Keys' AS assertion_name,
        COUNT(*) AS violation_count
    FROM dbo.dw_fact_sales
    WHERE customer_key IS NULL OR product_key IS NULL OR location_key IS NULL OR purchase_date_key IS NULL

    UNION ALL

    -- Kiểm tra 2: Không có Orphan Key nào trong dw_fact_sales không tồn tại ở các bảng Dimension
    SELECT
        'Fact_Sales_Referential_Integrity',
        COUNT(*)
    FROM dbo.dw_fact_sales fs
    WHERE NOT EXISTS (SELECT 1 FROM dbo.dw_dim_customer dc WHERE dc.customer_key = fs.customer_key)
       OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_product  dp WHERE dp.product_key  = fs.product_key)
       OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_location dl WHERE dl.location_key = fs.location_key)
       OR NOT EXISTS (SELECT 1 FROM dbo.dw_dim_date     dd WHERE dd.date_key     = fs.purchase_date_key)

    UNION ALL

    -- Kiểm tra 3: Không có giá trị tài chính âm trong dw_fact_orders
    SELECT
        'Fact_Orders_Non_Negative_Measures',
        COUNT(*)
    FROM dbo.dw_fact_orders
    WHERE total_item_price < 0 OR total_freight_value < 0 OR total_payment_value < 0
)
SELECT
    assertion_name,
    violation_count,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS assertion_status
FROM dw_assertions;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Lỗi khóa ngoại NULL, khóa mồ côi hoặc dữ liệu âm có thể lọt âm thầm vào kho sau khi nạp,
--      đến khi người dùng mở Dashboard mới phát hiện số liệu sai lệch nghiêm trọng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Các bài kiểm tra tự động (DW Quality Assertions) rà soát 100% tính toàn vẹn tham chiếu và miền giá trị ngay sau khi nạp Fact,
--      trả về trạng thái PASS/FAIL rõ ràng để chặn kịp thời trước khi làm mới báo cáo BI.


-- ------------------------------------------------------------------------------------------
-- Câu 4.7.3:
-- Đóng gói toàn bộ quy trình xây dựng Data Warehouse thành một Master Stored Procedure:
-- `usp_Build_Olist_DataWarehouse`:
-- Tự động vận hành toàn bộ từ Staging đến Fact, ghi nhận lịch sử thực thi và số bản ghi của từng bảng vào bảng nhật ký.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 4.7.3 TẠI ĐÂY:

IF OBJECT_ID('dbo.dw_pipeline_audit_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dw_pipeline_audit_log (
        run_id              INT IDENTITY(1,1) PRIMARY KEY,
        procedure_name      VARCHAR(100),
        start_time          DATETIME2,
        end_time            DATETIME2,
        duration_sec        INT,
        stg_orders_cnt      INT,
        dim_customer_cnt    INT,
        dim_product_cnt     INT,
        dim_location_cnt    INT,
        fact_sales_cnt      INT,
        fact_orders_cnt     INT,
        status              VARCHAR(20),
        error_message       NVARCHAR(MAX) NULL
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Build_Olist_DataWarehouse
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @start_time DATETIME2 = CURRENT_TIMESTAMP;
    DECLARE @stg_cnt INT = 0, @dc_cnt INT = 0, @dp_cnt INT = 0, @dl_cnt INT = 0, @fs_cnt INT = 0, @fo_cnt INT = 0;

    BEGIN TRY
        -- BƯỚC 1: NẠP TẦNG STAGING (Truncate & Reload)
        TRUNCATE TABLE stg.stg_dw_orders;
        INSERT INTO stg.stg_dw_orders (
            order_id, customer_id, order_status, order_purchase_timestamp,
            order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
        )
        SELECT
            TRIM(order_id), TRIM(customer_id), LOWER(TRIM(order_status)),
            CAST(order_purchase_timestamp AS DATETIME2), CAST(order_approved_at AS DATETIME2),
            CAST(order_delivered_carrier_date AS DATETIME2), CAST(order_delivered_customer_date AS DATETIME2),
            CAST(order_estimated_delivery_date AS DATETIME2)
        FROM dbo.olist_orders_dataset
        WHERE order_id IS NOT NULL AND customer_id IS NOT NULL AND order_status IS NOT NULL
          AND order_purchase_timestamp IS NOT NULL
          AND (order_delivered_customer_date IS NULL OR order_delivered_customer_date >= order_purchase_timestamp);
        SET @stg_cnt = @@ROWCOUNT;

        TRUNCATE TABLE stg.stg_dw_customers;
        WITH ranked_cust AS (
            SELECT
                TRIM(c.customer_unique_id) AS customer_unique_id,
                RIGHT('00000' + CAST(ISNULL(c.customer_zip_code_prefix, 0) AS VARCHAR(10)), 5) AS customer_zip_code,
                ISNULL(c.customer_zip_code_prefix, -1) AS zip_code_prefix,
                UPPER(TRIM(ISNULL(c.customer_city, N'UNKNOWN'))) AS customer_city,
                UPPER(TRIM(ISNULL(c.customer_state, 'XX')))     AS customer_state,
                ROW_NUMBER() OVER (PARTITION BY c.customer_unique_id ORDER BY o.order_purchase_timestamp DESC, c.customer_id DESC) AS rn
            FROM dbo.olist_customers_dataset c
            LEFT JOIN dbo.olist_orders_dataset o ON c.customer_id = o.customer_id
            WHERE c.customer_unique_id IS NOT NULL
        )
        INSERT INTO stg.stg_dw_customers (customer_unique_id, customer_zip_code, zip_code_prefix, customer_city, customer_state)
        SELECT customer_unique_id, customer_zip_code, zip_code_prefix, customer_city, customer_state
        FROM ranked_cust WHERE rn = 1;

        TRUNCATE TABLE stg.stg_dw_products;
        INSERT INTO stg.stg_dw_products (product_id, product_category_name, product_weight_kg, product_volume_m3)
        SELECT
            TRIM(product_id),
            LOWER(TRIM(COALESCE(NULLIF(product_category_name, N''), N'unknown'))),
            CAST(ISNULL(product_weight_g, 0) / 1000.0 AS DECIMAL(10, 4)),
            CAST((ISNULL(CAST(product_length_cm AS BIGINT), 0) * ISNULL(CAST(product_height_cm AS BIGINT), 0) * ISNULL(CAST(product_width_cm AS BIGINT), 0)) / 1000000.0 AS DECIMAL(12, 6))
        FROM dbo.olist_products_dataset WHERE product_id IS NOT NULL;

        -- BƯỚC 2 & 3: NẠP DIMENSIONS VÀ FACTS TRONG 1 TRANSACTION NGUYÊN TỬ
        BEGIN TRANSACTION;

            -- Dim Customer (Unknown + Insert + SCD Type 1)
            IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_customer WHERE customer_key = -1)
            BEGIN
                SET IDENTITY_INSERT dbo.dw_dim_customer ON;
                INSERT INTO dbo.dw_dim_customer (customer_key, customer_unique_id, customer_zip_code, customer_city, customer_state)
                VALUES (-1, 'UNKNOWN', '00000', N'Unknown Customer', 'XX');
                SET IDENTITY_INSERT dbo.dw_dim_customer OFF;
            END;

            MERGE INTO dbo.dw_dim_customer WITH (UPDLOCK, HOLDLOCK) AS tgt
            USING stg.stg_dw_customers AS src ON tgt.customer_unique_id = src.customer_unique_id
            WHEN MATCHED AND tgt.customer_key <> -1 AND (
                tgt.customer_zip_code <> src.customer_zip_code OR tgt.customer_city <> src.customer_city OR tgt.customer_state <> src.customer_state
            ) THEN
                UPDATE SET tgt.customer_zip_code = src.customer_zip_code, tgt.customer_city = src.customer_city, tgt.customer_state = src.customer_state, tgt.updated_at = CURRENT_TIMESTAMP
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (customer_unique_id, customer_zip_code, customer_city, customer_state)
                VALUES (src.customer_unique_id, src.customer_zip_code, src.customer_city, src.customer_state);

            -- Dim Product
            IF NOT EXISTS (SELECT 1 FROM dbo.dw_dim_product WHERE product_key = -1)
            BEGIN
                SET IDENTITY_INSERT dbo.dw_dim_product ON;
                INSERT INTO dbo.dw_dim_product (product_key, product_id, product_category_name, product_weight_kg, weight_tier, product_volume_m3, volume_tier)
                VALUES (-1, 'UNKNOWN', N'Unknown Product', 0, 'Unknown', 0, 'Unknown');
                SET IDENTITY_INSERT dbo.dw_dim_product OFF;
            END;

            INSERT INTO dbo.dw_dim_product (product_id, product_category_name, product_weight_kg, weight_tier, product_volume_m3, volume_tier)
            SELECT
                p.product_id, p.product_category_name, p.product_weight_kg,
                CASE WHEN p.product_weight_kg <= 0.5 THEN 'Light' WHEN p.product_weight_kg <= 5.0 THEN 'Medium' ELSE 'Heavy' END,
                p.product_volume_m3,
                CASE WHEN p.product_volume_m3 <= 0.005 THEN 'Small Box' WHEN p.product_volume_m3 <= 0.050 THEN 'Medium Box' ELSE 'Large Box' END
            FROM stg.stg_dw_products p
            WHERE NOT EXISTS (SELECT 1 FROM dbo.dw_dim_product dp WHERE dp.product_id = p.product_id);

            -- Fact Sales (Idempotent Insert)
            INSERT INTO dbo.dw_fact_sales (
                order_id, order_item_id, customer_key, product_key, location_key, purchase_date_key,
                order_status, quantity, unit_price, freight_value, total_item_amount
            )
            SELECT
                oi.order_id, oi.order_item_id,
                ISNULL(dc.customer_key, -1), ISNULL(dp.product_key, -1), ISNULL(dl.location_key, -1), ISNULL(dd.date_key, -1),
                o.order_status, 1,
                CAST(ISNULL(oi.price, 0) AS DECIMAL(18, 2)),
                CAST(ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2)),
                CAST(ISNULL(oi.price, 0) + ISNULL(oi.freight_value, 0) AS DECIMAL(18, 2))
            FROM dbo.olist_order_items_dataset oi
            INNER JOIN stg.stg_dw_orders o ON oi.order_id = o.order_id
            LEFT JOIN dbo.olist_customers_dataset raw_c ON o.customer_id = raw_c.customer_id
            LEFT JOIN dbo.dw_dim_customer dc ON raw_c.customer_unique_id = dc.customer_unique_id
            LEFT JOIN dbo.dw_dim_product dp ON oi.product_id = dp.product_id
            LEFT JOIN dbo.dw_dim_location dl ON raw_c.customer_zip_code_prefix = dl.zip_code_prefix
            LEFT JOIN dbo.dw_dim_date dd ON dd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_purchase_timestamp, 112))
            WHERE NOT EXISTS (SELECT 1 FROM dbo.dw_fact_sales fs WHERE fs.order_id = oi.order_id AND fs.order_item_id = oi.order_item_id);

            -- Fact Orders (Idempotent Insert)
            WITH item_sum AS (
                SELECT order_id, COUNT(*) AS item_cnt, CAST(SUM(price) AS DECIMAL(18, 2)) AS item_price, CAST(SUM(freight_value) AS DECIMAL(18, 2)) AS freight_val
                FROM dbo.olist_order_items_dataset GROUP BY order_id
            ),
            pay_sum AS (
                SELECT order_id, CAST(SUM(payment_value) AS DECIMAL(18, 2)) AS pay_val, MAX(payment_type) AS main_pay
                FROM dbo.olist_order_payments_dataset GROUP BY order_id
            )
            INSERT INTO dbo.dw_fact_orders (
                order_id, customer_key, location_key, purchase_date_key, delivered_date_key,
                order_status, primary_payment_type, item_count, total_item_price, total_freight_value,
                total_order_amount, total_payment_value, delivery_days, is_on_time_sla
            )
            SELECT
                o.order_id, ISNULL(dc.customer_key, -1), ISNULL(dl.location_key, -1),
                ISNULL(dpd.date_key, -1), ISNULL(ddd.date_key, -1),
                o.order_status, ISNULL(ps.main_pay, N'unknown'),
                ISNULL(its.item_cnt, 0), ISNULL(its.item_price, 0), ISNULL(its.freight_val, 0),
                CAST(ISNULL(its.item_price, 0) + ISNULL(its.freight_val, 0) AS DECIMAL(18, 2)),
                ISNULL(ps.pay_val, 0),
                CASE WHEN o.order_delivered_customer_date IS NOT NULL THEN DATEDIFF(DAY, o.order_purchase_timestamp, o.order_delivered_customer_date) ELSE NULL END,
                CASE WHEN o.order_delivered_customer_date IS NOT NULL AND CAST(o.order_delivered_customer_date AS DATE) <= CAST(o.order_estimated_delivery_date AS DATE) THEN 1 ELSE 0 END
            FROM stg.stg_dw_orders o
            LEFT JOIN dbo.olist_customers_dataset raw_c ON o.customer_id = raw_c.customer_id
            LEFT JOIN dbo.dw_dim_customer dc ON raw_c.customer_unique_id = dc.customer_unique_id
            LEFT JOIN dbo.dw_dim_location dl ON raw_c.customer_zip_code_prefix = dl.zip_code_prefix
            LEFT JOIN dbo.dw_dim_date dpd ON dpd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_purchase_timestamp, 112))
            LEFT JOIN dbo.dw_dim_date ddd ON ddd.date_key = CONVERT(INT, CONVERT(VARCHAR(8), o.order_delivered_customer_date, 112))
            LEFT JOIN item_sum its ON o.order_id = its.order_id
            LEFT JOIN pay_sum ps ON o.order_id = ps.order_id
            WHERE NOT EXISTS (SELECT 1 FROM dbo.dw_fact_orders fo WHERE fo.order_id = o.order_id);

            SELECT @dc_cnt = COUNT(*) FROM dbo.dw_dim_customer;
            SELECT @dp_cnt = COUNT(*) FROM dbo.dw_dim_product;
            SELECT @dl_cnt = COUNT(*) FROM dbo.dw_dim_location;
            SELECT @fs_cnt = COUNT(*) FROM dbo.dw_fact_sales;
            SELECT @fo_cnt = COUNT(*) FROM dbo.dw_fact_orders;

        COMMIT TRANSACTION;

        INSERT INTO dbo.dw_pipeline_audit_log (
            procedure_name, start_time, end_time, duration_sec,
            stg_orders_cnt, dim_customer_cnt, dim_product_cnt, dim_location_cnt, fact_sales_cnt, fact_orders_cnt, status
        )
        VALUES (
            'dbo.usp_Build_Olist_DataWarehouse', @start_time, CURRENT_TIMESTAMP, DATEDIFF(SECOND, @start_time, CURRENT_TIMESTAMP),
            @stg_cnt, @dc_cnt, @dp_cnt, @dl_cnt, @fs_cnt, @fo_cnt, 'SUCCESS'
        );

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.dw_pipeline_audit_log (
            procedure_name, start_time, end_time, duration_sec, status, error_message
        )
        VALUES (
            'dbo.usp_Build_Olist_DataWarehouse', @start_time, CURRENT_TIMESTAMP, DATEDIFF(SECOND, @start_time, CURRENT_TIMESTAMP),
            'FAILED', ERROR_MESSAGE()
        );

        THROW;
    END CATCH;
END;
GO

-- Thực thi Master Stored Procedure (sau khi đã chạy 4.3.2/4.3.3 và 4.4.1/4.4.2):
-- EXEC dbo.usp_Build_Olist_DataWarehouse;
-- SELECT * FROM dbo.dw_pipeline_audit_log;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Toàn bộ quy trình nạp kho gồm hàng chục script rời rạc sẽ không thể tự động hóa qua SQL Agent, Airflow hay Azure Data Factory;
--      nếu một bảng Fact lỗi giữa chừng sẽ để lại kho dữ liệu mất đồng bộ mà không có nhật ký lỗi tập trung.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Master Stored Procedure `dbo.usp_Build_Olist_DataWarehouse` đóng gói trọn vẹn luồng Staging -> Dimension -> Fact
--      kèm giao dịch nguyên tử (Transaction) và bảng nhật ký chi tiết số bản ghi của toàn kho sau mỗi lần chạy.
