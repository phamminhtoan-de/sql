-- ==========================================================================================
-- ████████████████████████████████████████████████████████████████████████████████████████
-- PHẦN 2: UPSERT STRATEGY (CẬP NHẬT & CHÈN DỮ LIỆU ĐÍCH)
-- Logic cốt lõi: Khóa đã tồn tại? → Có: UPDATE | Không: INSERT
-- ████████████████████████████████████████████████████████████████████████████████████████
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 1]: PHÂN LUỒNG INSERT VS UPDATE CƠ BẢN
-- ------------------------------------------------------------------------------------------

-- Câu 2.1.1:
-- Từ tập dữ liệu gia tăng ở tầng Staging, hãy phân tách rõ ràng thành 2 tập dữ liệu riêng biệt:
-- 1. Tập các bản ghi mới tinh (chưa từng xuất hiện ở bảng đích $\rightarrow$ cần INSERT).
-- 2. Tập các bản ghi đã tồn tại ở bảng đích nhưng có thông tin thay đổi $\rightarrow$ cần UPDATE.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.1.1 TẠI ĐÂY:

-- 1. Tập các bản ghi mới tinh (chưa từng xuất hiện ở bảng đích -> cần INSERT)
SELECT 
    src.customer_id,
    src.customer_unique_id,
    src.customer_zip_code_prefix,
    src.customer_city,
    src.customer_state,
    'INSERT' AS target_action 
FROM stg.stg_customers AS src 
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.olist_customers_dataset AS tgt
    WHERE tgt.customer_id = src.customer_id
);

-- 2. Tập các bản ghi đã tồn tại ở bảng đích nhưng có thông tin thay đổi -> cần UPDATE
SELECT 
    src.customer_id,
    src.customer_unique_id,
    src.customer_zip_code_prefix AS new_zip_code,
    src.customer_city            AS new_city,
    src.customer_state           AS new_state,
    tgt.customer_zip_code_prefix AS old_zip_code,
    tgt.customer_city            AS old_city,
    tgt.customer_state           AS old_state,
    'UPDATE' AS target_action
FROM stg.stg_customers AS src
INNER JOIN dbo.olist_customers_dataset AS tgt 
    ON src.customer_id = tgt.customer_id
WHERE 
    ISNULL(src.customer_zip_code_prefix, -1) <> ISNULL(tgt.customer_zip_code_prefix, -1)
    OR ISNULL(src.customer_city, '')          <> ISNULL(tgt.customer_city, '')
    OR ISNULL(src.customer_state, '')         <> ISNULL(tgt.customer_state, '');

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (PHÂN TÁCH LUỒNG INSERT VS UPDATE):
-- 1. Bài toán giải quyết (Audit & Data Profiling trước khi nạp):
--    - Trước khi ghi dữ liệu vào kho, kỹ sư dữ liệu cần phân tích và kiểm toán trước tỉ lệ
--      bản ghi mới (chèn mới) và bản ghi cũ (cập nhật) để đánh giá quy mô tải (Batch Sizing).
-- 2. Kỹ thuật áp dụng (NOT EXISTS & Differential Matching):
--    - Mệnh đề NOT EXISTS giúp bắt trọn các bản ghi mới tinh mà không bị ảnh hưởng bởi giá trị NULL.
--    - Điều kiện so sánh ở mệnh đề WHERE của tập UPDATE dùng ISNULL để tránh bẫy ba ngôi True/False/Unknown của SQL.



-- ------------------------------------------------------------------------------------------
-- Câu 2.1.2:
-- Thực hiện câu lệnh INSERT có điều kiện bảo vệ:
-- Chỉ chèn các bản ghi khách hàng từ Staging vào bảng đích nếu mã khách hàng đó chưa từng tồn tại ở đích,
-- đảm bảo tuyệt đối không sinh ra lỗi trùng khóa chính.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.1.2 TẠI ĐÂY:

-- 1. INSERT có điều kiện bảo vệ (Guarded INSERT)
INSERT INTO dbo.olist_customers_dataset (
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    created_at,
    updated_at
)
SELECT 
    src.customer_id,
    src.customer_unique_id,
    src.customer_zip_code_prefix,
    src.customer_city,
    src.customer_state,
    CURRENT_TIMESTAMP AS created_at,
    CURRENT_TIMESTAMP AS updated_at
FROM stg.stg_customers AS src
WHERE NOT EXISTS (
    -- Điều kiện bảo vệ: Đảm bảo khách hàng chưa từng tồn tại ở bảng đích
    SELECT 1 
    FROM dbo.olist_customers_dataset AS tgt
    WHERE tgt.customer_id = src.customer_id
);

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (GUARDED INSERT TRÁNH TRÙNG KHÓA CHÍNH):
-- 1. Bài toán giải quyết (Idempotency & Chống lỗi Duplicate Key):
--    - Trong thực tế, pipeline có thể bị chạy lại (re-run) nhiều lần do lỗi mạng hoặc retry tự động.
--    - Nếu dùng INSERT thông thường, hệ thống sẽ văng lỗi vi phạm khóa chính (Primary Key Violation).
-- 2. Cơ chế bảo vệ (NOT EXISTS vs NOT IN):
--    - Luôn ưu tiên dùng WHERE NOT EXISTS thay vì NOT IN vì NOT IN sẽ trả về rỗng nếu tập đích chứa giá trị NULL,
--      đồng thời NOT EXISTS được tối ưu hóa tốt hơn qua Anti-Semi-Join trong Execution Plan.



-- ------------------------------------------------------------------------------------------
-- Câu 2.1.3:
-- Thực hiện câu lệnh UPDATE có điều kiện tối ưu:
-- Cập nhật thông tin địa chỉ mới cho các khách hàng đã tồn tại ở bảng đích dựa trên dữ liệu từ Staging,
-- nhưng chỉ cập nhật các dòng thực sự có sự thay đổi về mặt nội dung (tránh cập nhật vô ích).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.1.3 TẠI ĐÂY:

-- 1. UPDATE có điều kiện tối ưu (Loại bỏ cập nhật vô ích)
UPDATE tgt 
SET 
    tgt.customer_city  = src.customer_city,
    tgt.customer_state = src.customer_state,
    tgt.updated_at     = CURRENT_TIMESTAMP
FROM dbo.olist_customers_dataset AS tgt
INNER JOIN stg.stg_customers AS src
    ON tgt.customer_id = src.customer_id
WHERE 
    -- Điều kiện tối ưu: Chỉ UPDATE những dòng thực sự có sự thay đổi
    ISNULL(tgt.customer_city, '')     <> ISNULL(src.customer_city, '')
    OR ISNULL(tgt.customer_state, '') <> ISNULL(src.customer_state, '');

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (TỐI ƯU UPDATE & KHỬ GHOST UPDATES):
-- 1. Bài toán giải quyết (Ghost Updates / No-Op Updates):
--    - Khi nạp dữ liệu gia tăng, phần lớn bản ghi cũ không hề có sự thay đổi.
--    - Việc ghi đè dữ liệu cũ bằng chính nó gây lãng phí nghiêm trọng dung lượng Transaction Log (.LDF),
--      gây khóa bảng (Locking/Blocking) kéo dài và làm hỏng dấu vết thời gian cập nhật (Audit Timestamp).
-- 2. Kỹ thuật áp dụng (Change Detection):
--    - Sử dụng phép so sánh giá trị cũ và mới kết hợp ISNULL để đảm bảo chỉ những dòng thực sự đổi mới được ghi đĩa.



-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 2]: CHIẾN LƯỢC UPSERT 2 BƯỚC ĐỘC LẬP (TWO-STEP UPSERT)
-- ------------------------------------------------------------------------------------------

-- Câu 2.2.1:
-- Viết quy trình Two-Step Upsert đồng bộ trạng thái đơn hàng:
-- Bước 1: Thực hiện UPDATE trạng thái mới cho các đơn hàng đã có ở bảng đích.
-- Bước 2: Thực hiện INSERT toàn bộ các đơn hàng mới phát sinh vào bảng đích.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.2.1 TẠI ĐÂY:

-- 1. Bước 1: UPDATE trạng thái mới cho các đơn hàng đã tồn tại ở bảng đích
UPDATE tgt
SET 
    tgt.order_status                  = src.order_status,
    tgt.order_approved_at             = src.order_approved_at,
    tgt.order_delivered_carrier_date  = src.order_delivered_carrier_date,
    tgt.order_delivered_customer_date = src.order_delivered_customer_date
FROM dbo.olist_orders_dataset AS tgt
INNER JOIN stg.stg_orders AS src
    ON tgt.order_id = src.order_id
WHERE 
    ISNULL(tgt.order_status, '') <> ISNULL(src.order_status, '');


INSERT INTO dbo.olist_orders_dataset (
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date
)
SELECT 
    src.order_id,
    src.customer_id,
    src.order_status,
    src.order_purchase_timestamp,
    src.order_approved_at,
    src.order_delivered_carrier_date,
    src.order_delivered_customer_date,
    src.order_estimated_delivery_date
FROM stg.stg_orders AS src
WHERE NOT EXISTS (
    -- Điều kiện bảo vệ: Đảm bảo đơn hàng chưa từng tồn tại ở đích trước khi chèn
    SELECT 1 
    FROM dbo.olist_orders_dataset AS tgt 
    WHERE tgt.order_id = src.order_id
);

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (TWO-STEP UPSERT STRATEGY):
-- 1. Bài toán giải quyết (Đồng bộ hai luồng dữ liệu gia tăng):
--    - Phân tách rõ ràng vòng đời của dữ liệu: Đơn hàng cũ đổi trạng thái (UPDATE) và đơn hàng mới tinh phát sinh (INSERT).
--    - Đảm bảo tính toàn vẹn (Data Integrity), ngăn chặn tuyệt đối lỗi vi phạm khóa chính (Primary Key Violation) làm dừng pipeline.
-- 2. Tối ưu tài nguyên hệ thống (Eliminate Ghost Updates):
--    - Mệnh đề WHERE so sánh trạng thái giúp database chỉ ghi đè đúng những dòng có sự thay đổi thực sự.
--    - Tiết kiệm dung lượng Transaction Log (.LDF), tránh phân mảnh chỉ mục (Index Fragmentation) và giảm thiểu khóa bảng (Table Locking).
-- 3. Nguyên tắc thứ tự thực thi (UPDATE trước -> INSERT sau):
--    - Luôn chạy câu lệnh UPDATE trước để xử lý các đơn hàng cũ.
--    - Nếu INSERT trước, các đơn hàng mới vừa được chèn sẽ lập tức bị quét và kiểm tra lại ở câu lệnh UPDATE phía sau, gây lãng phí tài nguyên tính toán.


-- ------------------------------------------------------------------------------------------
-- Câu 2.2.2:
-- Kiểm tra độ lệch và số dòng tác động của từng bước:
-- Đo lường chính xác số dòng đã được UPDATE ở Bước 1 và số dòng đã được INSERT ở Bước 2.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.2.2 TẠI ĐÂY:

-- 1. Truy vấn kiểm tra độ lệch và phân loại số dòng tác động (Data Reconciliation Query)
SELECT 
    COUNT(*) AS total_staging_rows,
    
    -- Nhóm 1: Số đơn hàng mới tinh cần INSERT (Khóa chính chưa xuất hiện ở bảng đích)
    COUNT(CASE 
        WHEN tgt.order_id IS NULL THEN 1 
    END) AS expected_inserted_rows,
    
    -- Nhóm 2: Số đơn hàng đã tồn tại nhưng có thay đổi trạng thái cần UPDATE
    COUNT(CASE 
        WHEN tgt.order_id IS NOT NULL 
         AND ISNULL(tgt.order_status, '') <> ISNULL(src.order_status, '') THEN 1 
    END) AS expected_updated_rows,

    -- Nhóm 3: Số đơn hàng đã tồn tại và giữ nguyên trạng thái (Bỏ qua, tránh Ghost Update)
    COUNT(CASE 
        WHEN tgt.order_id IS NOT NULL 
         AND ISNULL(tgt.order_status, '') = ISNULL(src.order_status, '') THEN 1 
    END) AS expected_unchanged_rows,

    -- Kiểm tra độ lệch: Tổng staging trừ đi cả 3 nhóm (Giá trị bắt buộc phải bằng 0)
    COUNT(*) - (
        COUNT(CASE WHEN tgt.order_id IS NULL THEN 1 END) +
        COUNT(CASE WHEN tgt.order_id IS NOT NULL AND ISNULL(tgt.order_status, '') <> ISNULL(src.order_status, '') THEN 1 END) +
        COUNT(CASE WHEN tgt.order_id IS NOT NULL AND ISNULL(tgt.order_status, '') = ISNULL(src.order_status, '') THEN 1 END)
    ) AS discrepancy
FROM stg.stg_orders AS src
LEFT JOIN dbo.olist_orders_dataset AS tgt 
    ON src.order_id = tgt.order_id;

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (DATA RECONCILIATION & AUDIT METRICS):
-- 1. Bài toán giải quyết (Kiểm toán tính toàn vẹn dữ liệu - Data Integrity Audit):
--    - Trong các pipeline cấp doanh nghiệp, bước kiểm toán (Reconciliation) là chốt chặn quan trọng
--      nhằm đảm bảo không có bất kỳ bản ghi nào bị thất thoát hoặc bị nhân bản vô tình (Cartesian Fan-Out).
-- 2. Kỹ thuật đối soát toàn diện (Exhaustive Categorization):
--    - Mọi bản ghi ở Staging sau khi LEFT JOIN với Target bắt buộc phải được gom triệt để vào 1 trong 3 nhóm duy nhất:
--      (1) Mới tinh -> Cần INSERT, (2) Thay đổi -> Cần UPDATE, (3) Giữ nguyên -> UNCHANGED.
--    - Giá trị discrepancy = 0 khẳng định tính toàn vẹn tuyệt đối trước khi hoặc sau khi nạp kho.
-- 3. Đo lường Runtime thực tế (Production Tip với @@ROWCOUNT):
--    - Khi quy trình Two-Step Upsert chạy trong Stored Procedure, ta dùng biến hệ thống @@ROWCOUNT ngay sau mỗi lệnh
--      (SET @rows_updated = @@ROWCOUNT và SET @rows_inserted = @@ROWCOUNT) để ghi nhật ký vào bảng Audit Log.


-- ------------------------------------------------------------------------------------------
-- Câu 2.2.3:
-- Đóng gói quy trình Two-Step Upsert vào một Transaction:
-- Đảm bảo tính nguyên tử (Atomicity): Cả 2 bước phải cùng thành công, nếu một bước lỗi thì toàn bộ bị hủy bỏ.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.2.3 TẠI ĐÂY:

-- 1. Kích hoạt cờ an toàn: Tự động hủy bỏ và rollback nếu có lỗi nghiêm trọng ở mức kết nối
SET XACT_ABORT ON;

BEGIN TRY
    -- 2. Mở khối giao dịch nguyên tử (Atomic Transaction)
    BEGIN TRANSACTION;

        -- Bước 1: UPDATE trạng thái mới cho các đơn hàng cũ đã tồn tại
        UPDATE tgt
        SET 
            tgt.order_status                  = src.order_status,
            tgt.order_approved_at             = src.order_approved_at,
            tgt.order_delivered_carrier_date  = src.order_delivered_carrier_date,
            tgt.order_delivered_customer_date = src.order_delivered_customer_date
        FROM dbo.olist_orders_dataset AS tgt
        INNER JOIN stg.stg_orders AS src
            ON tgt.order_id = src.order_id
        WHERE 
            ISNULL(tgt.order_status, '') <> ISNULL(src.order_status, '');

        -- Bước 2: INSERT các đơn hàng mới phát sinh (Guarded INSERT với NOT EXISTS)
        INSERT INTO dbo.olist_orders_dataset (
            order_id,
            customer_id,
            order_status,
            order_purchase_timestamp,
            order_approved_at,
            order_delivered_carrier_date,
            order_delivered_customer_date,
            order_estimated_delivery_date
        )
        SELECT 
            src.order_id,
            src.customer_id,
            src.order_status,
            src.order_purchase_timestamp,
            src.order_approved_at,
            src.order_delivered_carrier_date,
            src.order_delivered_customer_date,
            src.order_estimated_delivery_date
        FROM stg.stg_orders AS src
        WHERE NOT EXISTS (
            SELECT 1 
            FROM dbo.olist_orders_dataset AS tgt 
            WHERE tgt.order_id = src.order_id
        );

    -- 3. Xác nhận giao dịch thành công: Dữ liệu cả 2 bước chỉ được ghi cố định khi không có bất kỳ lỗi nào
    COMMIT TRANSACTION;

END TRY
BEGIN CATCH
    -- 4. Xử lý sự cố: Nếu có lỗi ở bất kỳ bước nào, rollback toàn bộ trạng thái về ban đầu
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    -- 5. Ném mã lỗi ra môi trường thực thi để hệ thống điều phối (Airflow / Data Factory) nhận diện sự cố
    THROW;
END CATCH;

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (TRANSACTION & ATOMICITY IN PIPELINES):
-- 1. Tính nguyên tử (Atomicity - Chữ 'A' trong chuẩn ACID):
--    - Đảm bảo quy tắc "Tất cả hoặc không gì cả" (All-or-Nothing). Ngăn chặn triệt để tình trạng dữ liệu dở dang
--      khi một trong hai bước gặp sự cố (mất điện, rớt mạng, lỗi dung lượng đĩa, vi phạm ràng buộc).
-- 2. Kiểm soát Rollback an toàn (@@TRANCOUNT):
--    - Biến hệ thống @@TRANCOUNT kiểm tra xem có giao dịch nào đang mở hay không trước khi phát lệnh ROLLBACK,
--      tránh sinh thêm lỗi phụ ("No transaction found") trong khối CATCH.
-- 3. Cơ chế cảnh báo lỗi tự động (THROW):
--    - Ném nguyên bản mã lỗi và thông điệp lỗi (Error Message) ra ngoài môi trường thực thi,
--      giúp các công cụ điều phối (Airflow, Azure Data Factory) nhận diện được sự cố và kích hoạt báo động ngay lập tức.


-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 3]: ĐỒNG BỘ DỮ LIỆU NGUYÊN KHỐI VỚI CÂU LỆNH MERGE
-- ------------------------------------------------------------------------------------------

-- Câu 2.3.1:
-- Viết một câu lệnh MERGE duy nhất để đồng bộ danh mục sản phẩm từ Staging vào bảng đích:
-- Khi tìm thấy mã sản phẩm trùng khớp: Cập nhật giá bán và trọng lượng mới.
-- Khi không tìm thấy mã sản phẩm: Chèn bản ghi sản phẩm mới vào bảng đích.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.3.1 TẠI ĐÂY:

merge into dbo.olist_products_dataset AS target 
using (
    select 
        product_id,
        product_category_name,
        product_name_lenght,
        product_description_lenght,
        product_photos_qty,
        product_weight_g,
        product_length_cm,
        product_height_cm,
        product_width_cm
    from stg.stg_products as src
)
as source on target.product_id = source.product_id  
when matched AND EXISTS (
    SELECT source.product_category_name, source.product_weight_g
    EXCEPT 
    SELECT target.product_category_name, target.product_weight_g
) 
then 
    update set 
        target.product_category_name = source.product_category_name,
        target.product_name_lenght = source.product_name_lenght,
        target.product_description_lenght = source.product_description_lenght,
        target.product_photos_qty = source.product_photos_qty,
        target.product_weight_g = source.product_weight_g,
        target.product_length_cm = source.product_length_cm,
        target.product_height_cm = source.product_height_cm,
        target.product_width_cm = source.product_width_cm
when not matched then 
    insert (
        product_id,
        product_category_name,
        product_name_lenght,
        product_description_lenght,
        product_photos_qty,
        product_weight_g,
        product_length_cm,
        product_height_cm,
        product_width_cm
    ) values (
        source.product_id,
        source.product_category_name,
        source.product_name_lenght,
        source.product_description_lenght,
        source.product_photos_qty,
        source.product_weight_g,
        source.product_length_cm,
        source.product_height_cm,
        source.product_width_cm
    );

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (ĐỒNG BỘ NGUYÊN KHỐI VỚI CÂU LỆNH MERGE):
-- 1. Bản chất cơ chế UPSERT nguyên khối (Atomic Synchronization):
--    - Gom toàn bộ logic kiểm tra tồn tại, UPDATE bản ghi cũ và INSERT bản ghi mới vào trong MỘT lượt quét (Single Scan).
--    - Tối ưu hiệu năng I/O vượt trội so với việc chạy 2 câu lệnh UPDATE và INSERT riêng lẻ.
-- 2. Kỹ thuật chống "Ghost Update" (Redundant Update Prevention):
--    - Mệnh đề 'WHEN MATCHED AND EXISTS (... EXCEPT ...)' ngăn chặn việc ghi đè vô nghĩa khi dữ liệu nguồn và đích hoàn toàn giống nhau.
--    - Tiết kiệm dung lượng Transaction Log (.LDF), tránh phân mảnh chỉ mục (Index Fragmentation) và giảm thiểu khóa bảng (Table Locking).
-- 3. Lưu ý cú pháp bắt buộc trong T-SQL:
--    - Câu lệnh MERGE luôn bắt buộc phải kết thúc bằng dấu chấm phẩy (;).

-- ------------------------------------------------------------------------------------------
-- Câu 2.3.2:
-- Sử dụng mệnh đề OUTPUT để theo dõi chi tiết hành vi của MERGE:
-- Xuất ra danh sách các hành động đã thực hiện ($action: 'INSERT' hoặc 'UPDATE') kèm theo khóa chính bị tác động.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.3.2 TẠI ĐÂY:


-- =====================================================================
-- KỊCH BẢN DEMO KIỂM THỬ MỆNH ĐỀ OUTPUT TRONG MERGE
-- =====================================================================

-- 1. TẠO BẢNG ĐÍCH GIẢ LẬP (Hiện đang có 2 sản phẩm: PROD_01 và PROD_02)
DROP TABLE IF EXISTS #target_products;
CREATE TABLE #target_products (
    product_id VARCHAR(50) PRIMARY KEY,
    product_category_name NVARCHAR(100),
    product_weight_g INT
);

INSERT INTO #target_products VALUES 
('PROD_01', N'Điện thoại', 200),
('PROD_02', N'Bàn phím', 500);

-- 2. TẠO BẢNG NGUỒN STAGING (Hôm nay có 2 sản phẩm: PROD_01 đổi cân nặng, PROD_03 mới tinh)
DROP TABLE IF EXISTS #stg_products;
CREATE TABLE #stg_products (
    product_id VARCHAR(50),
    product_category_name NVARCHAR(100),
    product_weight_g INT
);

INSERT INTO #stg_products VALUES 
('PROD_01', N'Điện thoại', 350),  -- Khớp khóa -> Sẽ kích hoạt UPDATE (đổi từ 200g lên 350g)
('PROD_03', N'Chuột máy tính', 150); -- Chưa có -> Sẽ kích hoạt INSERT

-- 3. CHẠY LỆNH MERGE CÓ MỆNH ĐỀ OUTPUT ĐỂ SOI KẾT QUẢ
MERGE INTO #target_products AS target
USING #stg_products AS source
    ON target.product_id = source.product_id

WHEN MATCHED THEN
    UPDATE SET 
        target.product_category_name = source.product_category_name,
        target.product_weight_g      = source.product_weight_g

WHEN NOT MATCHED THEN
    INSERT (product_id, product_category_name, product_weight_g)
    VALUES (source.product_id, source.product_category_name, source.product_weight_g)

-- 👇 Mệnh đề OUTPUT xuất ra chi tiết cả giá trị cũ (deleted) và mới (inserted):
OUTPUT 
    $action AS [Hành_Động],
    inserted.product_id AS [Mã_Sản_Phẩm],
    deleted.product_weight_g AS [Cân_Nặng_Cũ],
    inserted.product_weight_g AS [Cân_Nặng_Mới];

MERGE INTO dbo.olist_products_dataset AS target 
USING stg.stg_products AS source 
    ON target.product_id = source.product_id  
WHEN MATCHED THEN 
    UPDATE SET 
        target.product_category_name        = source.product_category_name,
        target.product_name_lenght          = source.product_name_lenght,
        target.product_description_lenght   = source.product_description_lenght,
        target.product_photos_qty           = source.product_photos_qty,
        target.product_weight_g             = source.product_weight_g,
        target.product_length_cm            = source.product_length_cm,
        target.product_height_cm            = source.product_height_cm,
        target.product_width_cm             = source.product_width_cm
WHEN NOT MATCHED THEN 
    INSERT (
        product_id,
        product_category_name,
        product_name_lenght,
        product_description_lenght,
        product_photos_qty,
        product_weight_g,
        product_length_cm,
        product_height_cm,
        product_width_cm
    ) VALUES (
        source.product_id,
        source.product_category_name,
        source.product_name_lenght,
        source.product_description_lenght,
        source.product_photos_qty,
        source.product_weight_g,
        source.product_length_cm,
        source.product_height_cm,
        source.product_width_cm
    )
OUTPUT 
    $action AS action_type,
    inserted.product_id AS affected_product_id;

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (MỆNH ĐỀ OUTPUT TRONG MERGE):
-- 1. Giám sát hành vi theo thời gian thực (Real-time Audit Logging):
--    - Mệnh đề OUTPUT cho phép bắt trọn từng dòng dữ liệu bị tác động ngay trong chu kỳ thực thi của MERGE.
--    - Cột ảo $action tự động phân loại hành động thành 'INSERT', 'UPDATE' hoặc 'DELETE'.
-- 2. Ứng dụng trong Data Pipeline:
--    - Có thể kết hợp 'OUTPUT ... INTO #AuditLog' để lưu vết kiểm toán, đối soát số liệu hoặc kích hoạt luồng cảnh báo tự động.


-- ------------------------------------------------------------------------------------------
-- Câu 2.3.3:
-- Phòng chống lỗi nổ khóa nguồn trong MERGE:
-- Phân tích và minh họa lý do tại sao lệnh MERGE sẽ bị sập nếu bảng Staging có chứa dữ liệu trùng lặp khóa,
-- và viết truy vấn làm sạch khóa Staging trước khi thực hiện MERGE.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.3.3 TẠI ĐÂY:

-- BƯỚC 1: Dùng CTE để đánh số thứ tự (ROW_NUMBER) lọc trùng lặp cho bảng Staging
WITH Deduplicated_Staging AS (
    SELECT 
        product_id,
        product_category_name,
        product_weight_g,
        -- Các cột khác...
        ROW_NUMBER() OVER (
            PARTITION BY product_id                -- Gom theo mã sản phẩm
            ORDER BY (SELECT NULL)                 -- Hoặc ORDER BY updated_at DESC nếu có ngày cập nhật
        ) AS row_num
    FROM stg.stg_products
)

-- BƯỚC 2: Gọi trực tiếp CTE đã lọc 'row_num = 1' vào mệnh đề USING
MERGE INTO dbo.olist_products_dataset AS target 
USING (
    SELECT * 
    FROM Deduplicated_Staging 
    WHERE row_num = 1                             -- 💡 Chìa khóa: Chỉ giữ lại đúng 1 dòng duy nhất!
) AS source 
    ON target.product_id = source.product_id  

WHEN MATCHED THEN 
    UPDATE SET 
        target.product_category_name = source.product_category_name,
        target.product_weight_g      = source.product_weight_g

WHEN NOT MATCHED THEN 
    INSERT (product_id, product_category_name, product_weight_g)
    VALUES (source.product_id, source.product_category_name, source.product_weight_g);

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (LỖI NỔ KHÓA NGUỒN & KỸ THUẬT DEDUPLICATION):
-- 1. Bản chất lỗi nổ khóa nguồn (Non-Deterministic MERGE - Error 8672):
--    - SQL Server yêu cầu quan hệ 1-1 giữa mỗi dòng đích và mỗi dòng nguồn trong mệnh đề ON.
--    - Nếu bảng Staging có từ 2 dòng trở lên trùng khóa chính, Database không thể xác định giá trị nào để UPDATE dòng đích -> Lập tức ném lỗi Error 8672 và Rollback toàn bộ transaction.
-- 2. Kỹ thuật Deduplication chuẩn mực với CTE & ROW_NUMBER():
--    - 'PARTITION BY product_id': Gom nhóm dữ liệu theo từng khóa chính duy nhất.
--    - 'ORDER BY updated_at DESC' (hoặc tiêu chí ưu tiên): Đảm bảo chọn đúng bản ghi mới nhất hoặc đáng tin cậy nhất.
--    - 'WHERE row_num = 1': Phễu lọc triệt để loại bỏ dữ liệu trùng lặp trước khi cấp phát vào mệnh đề USING của MERGE.



-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 4]: UPSERT TRÊN BẢNG FACT & BẢNG QUAN HỆ CHI TIẾT
-- ------------------------------------------------------------------------------------------

-- Câu 2.4.1:
-- Thực hiện Upsert trên bảng chi tiết mặt hàng FactOrderItems:
-- Cập nhật lại số lượng và phí vận chuyển đối với các món hàng có sự điều chỉnh,
-- và chèn các món hàng mới phát sinh của các đơn hàng mới.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.4.1 TẠI ĐÂY:

-- BƯỚC 1: Khử trùng lặp nguồn Staging mặt hàng (Deduplication Layer với Composite PK)
WITH deduplicated_order_items AS (
    SELECT 
        order_id,
        order_item_id,
        product_id,
        seller_id,
        shipping_limit_date,
        price,
        freight_value,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, order_item_id 
            ORDER BY shipping_limit_date DESC
        ) AS rn
    FROM stg.stg_order_items
)
-- BƯỚC 2: Thực thi MERGE Upsert vào FactOrderItems với khóa bảo vệ WITH (HOLDLOCK)
MERGE INTO dbo.olist_order_items_dataset WITH (HOLDLOCK) AS target
USING (
    SELECT 
        order_id,
        order_item_id,
        product_id,
        seller_id,
        shipping_limit_date,
        price,
        freight_value
    FROM deduplicated_order_items
    WHERE rn = 1
) AS source
    -- Mệnh đề ON: Ghép nối theo cặp Khóa chính ghép (Composite Primary Key)
    ON  target.order_id      = source.order_id 
    AND target.order_item_id = source.order_item_id

-- Mệnh đề MATCHED: Phát hiện thay đổi thông minh qua EXCEPT (chống Blind Update & an toàn NULL)
WHEN MATCHED AND EXISTS (
    SELECT source.product_id, source.seller_id, source.shipping_limit_date, source.price, source.freight_value
    EXCEPT 
    SELECT target.product_id, target.seller_id, target.shipping_limit_date, target.price, target.freight_value
) 
THEN 
    -- Nhánh UPDATE: Cập nhật thông tin hàng hóa, giá bán và cước vận chuyển thực tế
    UPDATE SET 
        target.product_id          = source.product_id,
        target.seller_id           = source.seller_id,
        target.shipping_limit_date = source.shipping_limit_date,
        target.price               = source.price,
        target.freight_value       = source.freight_value

-- Nhánh NOT MATCHED: Chèn mới các mặt hàng của đơn hàng mới phát sinh
WHEN NOT MATCHED THEN 
    INSERT (
        order_id,
        order_item_id,
        product_id,
        seller_id,
        shipping_limit_date,
        price,
        freight_value
    ) VALUES (
        source.order_id,
        source.order_item_id,
        source.product_id,
        source.seller_id,
        source.shipping_limit_date,
        source.price,
        source.freight_value
    );

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (UPSERT BẢNG FACT BÁN HÀNG CHI TIẾT):
-- 1. Đặc thù Composite Primary Key trong Fact Table:
--    - Bảng FactOrderItems không dùng khóa đơn mà định danh qua cặp (order_id, order_item_id).
--    - 'order_item_id' là số thứ tự món trong đơn (1, 2, 3...) - tuyệt đối không được đưa vào UPDATE SET vì làm thay đổi cấu trúc khóa.
-- 2. Tối ưu I/O và Transaction Log với toán tử EXCEPT:
--    - Bảng Fact thường có hàng triệu dòng. Kỹ thuật EXCEPT lọc chỉ cập nhật các dòng thực sự thay đổi giá hoặc phí ship,
--      tránh ghi đè vô ích (Blind Update), giúp giảm 90% dung lượng sinh ra trong Transaction Log (.ldf).


-- ------------------------------------------------------------------------------------------
-- Câu 2.4.2:
-- Thực hiện Upsert đồng bộ thông tin thanh toán:
-- Cập nhật số tiền thanh toán thực nhận nếu đơn có sự thay đổi về tổng thanh toán.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.4.2 TẠI ĐÂY:

-- BƯỚC 1: Khử trùng lặp nguồn Staging thanh toán theo cặp khóa giao dịch (order_id, payment_sequential)
WITH deduplicated_payments AS (
    SELECT 
        order_id,
        payment_sequential,
        payment_type,
        payment_installments,
        payment_value,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, payment_sequential 
            ORDER BY payment_value DESC               -- Hoặc updated_at DESC nếu có mốc thời gian
        ) AS rn
    FROM stg.stg_order_payments
    WHERE order_id IS NOT NULL
)
-- BƯỚC 2: Thực thi MERGE Upsert vào bảng Fact thanh toán với khóa bảo vệ WITH (HOLDLOCK)
MERGE INTO dbo.olist_order_payments_dataset WITH (HOLDLOCK) AS target
USING (
    SELECT 
        order_id,
        payment_sequential,
        payment_type,
        payment_installments,
        payment_value
    FROM deduplicated_payments
    WHERE rn = 1
) AS source 
    -- Mệnh đề ON: Ghép nối theo cặp khóa thứ tự đợt thanh toán của từng đơn
    ON  target.order_id           = source.order_id
    AND target.payment_sequential = source.payment_sequential

-- Mệnh đề MATCHED: Phát hiện chênh lệch số tiền thực nhận hoặc thay đổi phương thức thanh toán
WHEN MATCHED AND EXISTS (
    SELECT source.payment_type, source.payment_installments, source.payment_value
    EXCEPT 
    SELECT target.payment_type, target.payment_installments, target.payment_value
)
THEN
    -- Nhánh UPDATE: Cập nhật lại số tiền thanh toán thực nhận (payment_value) và thông tin liên quan
    UPDATE SET
        target.payment_type         = source.payment_type,
        target.payment_installments = source.payment_installments,
        target.payment_value        = source.payment_value

-- Nhánh NOT MATCHED: Chèn các đợt thanh toán phát sinh mới của đơn hàng
WHEN NOT MATCHED THEN
    INSERT (
        order_id,
        payment_sequential,     
        payment_type,
        payment_installments,
        payment_value
    ) VALUES (  
        source.order_id,
        source.payment_sequential,
        source.payment_type,
        source.payment_installments,
        source.payment_value
    );

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (ĐỒNG BỘ DỮ LIỆU THANH TOÁN ĐA ĐỢT):
-- 1. Mô hình thanh toán đa phương thức (Split Payments / Multi-tender):
--    - Một đơn hàng có thể thanh toán bằng nhiều hình thức (Voucher kết hợp Thẻ tín dụng).
--    - Việc liên kết qua cặp khóa (order_id, payment_sequential) đảm bảo tính toàn vẹn, không làm mất hoặc ghi đè các đợt thanh toán khác nhau.
-- 2. Tính toàn vẹn số liệu tài chính:
--    - Mọi sự điều chỉnh tiền thanh toán (payment_value) được cập nhật chính xác sẽ làm tiền đề đối soát doanh thu ở Câu 2.4.3.


-- ------------------------------------------------------------------------------------------
-- Câu 2.4.3:
-- Đối soát số liệu sau Upsert Fact Table:
-- Viết truy vấn kiểm tra tổng doanh thu và tổng số lượng món hàng trước và sau đợt Upsert
-- để xác nhận số liệu tài chính gia tăng một cách chính xác.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.4.3 TẠI ĐÂY:

-- KỊCH BẢN ĐỐI SOÁT KIỂM TOÁN TÀI CHÍNH & SẢN LƯỢNG (FINANCIAL RECONCILIATION AUDIT):

-- BƯỚC 1: Khởi tạo bảng tạm ghi nhận số liệu trước và sau Upsert (Pre/Post Load Audit Snapshot)
IF OBJECT_ID('tempdb..#fact_audit_snapshot') IS NOT NULL
    DROP TABLE #fact_audit_snapshot;

CREATE TABLE #fact_audit_snapshot (
    stage               VARCHAR(20),       -- 'PRE_UPSERT' hoặc 'POST_UPSERT'
    total_items         BIGINT,            -- Tổng số lượng món hàng (COUNT)
    total_revenue       DECIMAL(18, 2),    -- Tổng tiền hàng (SUM price)
    total_freight       DECIMAL(18, 2),    -- Tổng tiền cước (SUM freight_value)
    total_amount        DECIMAL(18, 2),    -- Tổng tiền đơn hàng (price + freight)
    snapshot_time       DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- BƯỚC 2: Chụp số liệu kiểm toán trước khi nạp (PRE_UPSERT SNAPSHOT)
-- (Trong pipeline thực tế, bước này chạy ngay trước khi thực thi lệnh MERGE)
INSERT INTO #fact_audit_snapshot (stage, total_items, total_revenue, total_freight, total_amount)
SELECT 
    'PRE_UPSERT'                              AS stage,
    COUNT(*)                                  AS total_items,
    ISNULL(SUM(price), 0)                     AS total_revenue,
    ISNULL(SUM(freight_value), 0)             AS total_freight,
    ISNULL(SUM(price + freight_value), 0)     AS total_amount
FROM dbo.olist_order_items_dataset;

-- (Giả lập: Tiến trình Upsert FactOrderItems ở Câu 2.4.1 được thực thi tại đây)

-- BƯỚC 3: Chụp số liệu kiểm toán sau khi nạp (POST_UPSERT SNAPSHOT)
INSERT INTO #fact_audit_snapshot (stage, total_items, total_revenue, total_freight, total_amount)
SELECT 
    'POST_UPSERT'                             AS stage,
    COUNT(*)                                  AS total_items,
    ISNULL(SUM(price), 0)                     AS total_revenue,
    ISNULL(SUM(freight_value), 0)             AS total_freight,
    ISNULL(SUM(price + freight_value), 0)     AS total_amount
FROM dbo.olist_order_items_dataset;

-- BƯỚC 4: Truy vấn đối soát số liệu gia tăng (Reconciliation Variance & Verification)
-- Đối chiếu mức tăng thực tế (Actual Delta) với mức tăng kỳ vọng từ Staging (Expected Delta)
WITH audit_pivoted AS (
    SELECT 
        MAX(CASE WHEN stage = 'PRE_UPSERT'  THEN total_items   END) AS pre_items,
        MAX(CASE WHEN stage = 'POST_UPSERT' THEN total_items   END) AS post_items,
        MAX(CASE WHEN stage = 'PRE_UPSERT'  THEN total_revenue END) AS pre_revenue,
        MAX(CASE WHEN stage = 'POST_UPSERT' THEN total_revenue END) AS post_revenue,
        MAX(CASE WHEN stage = 'PRE_UPSERT'  THEN total_freight END) AS pre_freight,
        MAX(CASE WHEN stage = 'POST_UPSERT' THEN total_freight END) AS post_freight,
        MAX(CASE WHEN stage = 'PRE_UPSERT'  THEN total_amount  END) AS pre_amount,
        MAX(CASE WHEN stage = 'POST_UPSERT' THEN total_amount  END) AS post_amount
    FROM #fact_audit_snapshot
),
expected_changes AS (
    -- Tính toán số liệu kỳ vọng từ tập Staging
    SELECT 
        COUNT(CASE WHEN tgt.order_id IS NULL THEN 1 END) AS expected_new_items,
        ISNULL(SUM(CASE WHEN tgt.order_id IS NULL THEN src.price END), 0)
        + ISNULL(SUM(CASE WHEN tgt.order_id IS NOT NULL THEN src.price - tgt.price END), 0) AS expected_revenue_delta
    FROM stg.stg_order_items src
    LEFT JOIN dbo.olist_order_items_dataset tgt
        ON src.order_id = tgt.order_id AND src.order_item_id = tgt.order_item_id
)
SELECT 
    p.pre_items,
    p.post_items,
    (p.post_items - p.pre_items)             AS delta_items,
    e.expected_new_items,
    p.pre_revenue,
    p.post_revenue,
    (p.post_revenue - p.pre_revenue)         AS delta_revenue,
    e.expected_revenue_delta,
    CASE 
        WHEN (p.post_items - p.pre_items) = e.expected_new_items
         AND (p.post_revenue - p.pre_revenue) = e.expected_revenue_delta
        THEN N'PASS (Đối soát tài chính khớp 100%)'
        ELSE N'FAIL (Phát hiện sai lệch doanh thu hoặc số lượng)'
    END AS reconciliation_status
FROM audit_pivoted p
CROSS JOIN expected_changes e;

-- GHI CHÚ KIẾN TRÚC & BÀI TOÁN THỰC TẾ (ĐỐI SOÁT DỮ LIỆU TÀI CHÍNH):
-- 1. Bản chất của Financial Reconciliation trong Data Pipeline:
--    - Khi nạp dữ liệu Fact (bán hàng/thanh toán), rủi ro lớn nhất là Double Counting (trùng lặp doanh thu) hoặc Missing Records (thất thoát bản ghi).
--    - Phương pháp Snapshot Pre/Post Load kết hợp Expected Delta từ Staging là tiêu chuẩn bắt buộc trong các Data Pipeline ngân hàng và thương mại điện tử.
-- 2. Quy tắc đối soát 2 chiều (Bidirectional Reconciliation):
--    - Chiều số lượng (Volume Check): delta_items phải đúng bằng số bản ghi mới tinh (New Inserts).
--    - Chiều giá trị (Value Check): delta_revenue phải đúng bằng (Doanh thu các món mới chèn + Chênh lệch điều chỉnh giá của các món cập nhật).
-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 5]: QUẢN LÝ XÓA MỀM (SOFT DELETE) TRONG QUY TRÌNH UPSERT
-- ------------------------------------------------------------------------------------------

-- Câu 2.5.1:
-- Khi hệ thống nguồn phát sinh bản ghi bị hủy bỏ hoặc xóa bỏ:
-- Viết câu lệnh Upsert cập nhật trạng thái xóa mềm (`is_deleted = 1` kèm ngày xóa) ở bảng đích
-- thay vì xóa bỏ dòng dữ liệu vật lý khỏi kho.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.5.1 TẠI ĐÂY:

-- Tạo bảng đích hỗ trợ Soft Delete (nếu chưa có) để minh họa an toàn trên E_commerce
IF OBJECT_ID('dbo.dim_customers_soft_delete', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_customers_soft_delete (
        customer_id              VARCHAR(50) PRIMARY KEY,
        customer_unique_id       VARCHAR(50),
        customer_zip_code_prefix INT,
        customer_city            NVARCHAR(200),
        customer_state           CHAR(2),
        is_deleted               BIT NOT NULL DEFAULT 0,
        deleted_at               DATETIME2 NULL,
        updated_at               DATETIME2 NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    INSERT INTO dbo.dim_customers_soft_delete (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
    SELECT TOP (1000) customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
    FROM dbo.olist_customers_dataset;
END;
GO

-- Tập nguồn giả lập chứa danh sách khách hàng còn hiệu lực ở nguồn (tức các mã vắng mặt ở nguồn là đã bị xóa)
WITH active_source AS (
    SELECT TOP (995)
        customer_id,
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state
    FROM dbo.olist_customers_dataset
)
MERGE INTO dbo.dim_customers_soft_delete WITH (HOLDLOCK) AS tgt
USING active_source AS src
    ON tgt.customer_id = src.customer_id
WHEN MATCHED AND tgt.is_deleted = 0 AND EXISTS (
    SELECT src.customer_zip_code_prefix, src.customer_city, src.customer_state
    EXCEPT
    SELECT tgt.customer_zip_code_prefix, tgt.customer_city, tgt.customer_state
) THEN
    UPDATE SET
        tgt.customer_zip_code_prefix = src.customer_zip_code_prefix,
        tgt.customer_city            = src.customer_city,
        tgt.customer_state           = src.customer_state,
        tgt.updated_at               = CURRENT_TIMESTAMP
WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
    VALUES (src.customer_id, src.customer_unique_id, src.customer_zip_code_prefix, src.customer_city, src.customer_state)
WHEN NOT MATCHED BY SOURCE AND tgt.is_deleted = 0 THEN
    -- Không DELETE vật lý: chỉ đánh dấu is_deleted = 1 và ghi nhận thời điểm xóa mềm
    UPDATE SET
        tgt.is_deleted = 1,
        tgt.deleted_at = CURRENT_TIMESTAMP,
        tgt.updated_at = CURRENT_TIMESTAMP;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu dùng DELETE vật lý trực tiếp ở bảng Dimension/Đích, toàn bộ dấu vết lịch sử biến mất;
--      các bảng Fact cũ tham chiếu tới mã khách hàng đó bị "mồ côi" (Orphan Records), mất liên kết khi làm báo cáo quá khứ
--      hoặc gây lỗi khóa ngoại (Foreign Key Violation).
--    - Nếu bỏ qua luôn không xử lý bản ghi bị xóa ở nguồn, bảng đích sẽ giữ lại "dữ liệu ma" (Phantom Records) làm sai lệch số lượng khách hàng đang hoạt động.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Nhánh WHEN NOT MATCHED BY SOURCE giữ nguyên dòng dữ liệu lịch sử cho các báo cáo quá khứ,
--      đồng thời đánh dấu is_deleted = 1 kèm deleted_at chính xác để kiểm toán (Audit) và lọc sạch ở tầng báo cáo.



-- ------------------------------------------------------------------------------------------
-- Câu 2.5.2:
-- Xử lý tình huống tái kích hoạt (Reactivation):
-- Nếu một bản ghi từng bị đánh dấu xóa mềm sau đó xuất hiện trở lại với dữ liệu mới ở nguồn,
-- hãy viết lệnh Upsert tự động đưa trạng thái trở lại `is_deleted = 0` và cập nhật thông tin mới nhất.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.5.2 TẠI ĐÂY:

WITH reactivated_source AS (
    -- Giả sử toàn bộ tập nguồn lúc này bao gồm cả những khách hàng từng bị xóa mềm ở câu 2.5.1 nay quay trở lại
    SELECT TOP (1000)
        customer_id,
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state
    FROM dbo.olist_customers_dataset
)
MERGE INTO dbo.dim_customers_soft_delete WITH (HOLDLOCK) AS tgt
USING reactivated_source AS src
    ON tgt.customer_id = src.customer_id
WHEN MATCHED AND (
    tgt.is_deleted = 1 -- Trường hợp 1: Bản ghi từng bị xóa mềm nay xuất hiện lại -> Reactivate!
    OR EXISTS (
        SELECT src.customer_zip_code_prefix, src.customer_city, src.customer_state
        EXCEPT
        SELECT tgt.customer_zip_code_prefix, tgt.customer_city, tgt.customer_state
    )
) THEN
    UPDATE SET
        tgt.customer_zip_code_prefix = src.customer_zip_code_prefix,
        tgt.customer_city            = src.customer_city,
        tgt.customer_state           = src.customer_state,
        tgt.is_deleted               = 0,
        tgt.deleted_at               = NULL,
        tgt.updated_at               = CURRENT_TIMESTAMP
WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
    VALUES (src.customer_id, src.customer_unique_id, src.customer_zip_code_prefix, src.customer_city, src.customer_state);
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Khi khách hàng/sản phẩm được mở lại ở hệ thống nguồn nhưng nhánh WHEN MATCHED chỉ so sánh cột nghiệp vụ (city/state)
--      mà quên kiểm tra cờ tgt.is_deleted = 1, dữ liệu đích vẫn bị kẹt mãi ở trạng thái is_deleted = 1.
--    - Hoặc nếu chỉ lọc WHERE is_deleted = 0 ở đích khi đối chiếu, câu lệnh sẽ tưởng bản ghi đó chưa có và thử INSERT mới -> văng lỗi Primary Key Violation.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Bản ghi tái kích hoạt tự động được khôi phục is_deleted = 0, xóa mốc deleted_at = NULL
--      và cập nhật đầy đủ thuộc tính mới nhất trong 1 câu MERGE duy nhất, không trùng khóa chính.



-- ------------------------------------------------------------------------------------------
-- Câu 2.5.3:
-- Xây dựng View báo cáo sạch:
-- Tạo View trên bảng đích tự động loại bỏ các bản ghi đã bị xóa mềm để phục vụ người dùng phân tích.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.5.3 TẠI ĐÂY:

GO
CREATE OR ALTER VIEW dbo.vw_active_customers AS
SELECT
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    updated_at
FROM dbo.dim_customers_soft_delete
WHERE is_deleted = 0;
GO

-- Kiểm tra dữ liệu sạch qua View:
SELECT COUNT(*) AS active_customer_count FROM dbo.vw_active_customers;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Mỗi nhân viên phân tích (Data Analyst / BI Developer) khi viết báo cáo đều phải tự nhớ thêm WHERE is_deleted = 0;
--      chỉ cần 1 báo cáo quên điều kiện này là tổng số khách hàng/doanh thu hiện hành bị đếm nhầm cả các bản ghi đã hủy.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Mọi công cụ BI (Power BI, Tableau, Looker) chỉ cần kết nối thẳng vào dbo.vw_active_customers là luôn nhận đúng tập dữ liệu hiện hành sạch sẽ,
--      trong khi bảng gốc vẫn bảo toàn 100% lịch sử cho kiểm toán.



-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 6]: TÍNH CHẤT IDEMPOTENT & CHỐNG XUNG ĐỘT TRUY CẬP (RACE CONDITIONS)
-- ------------------------------------------------------------------------------------------

-- Câu 2.6.1:
-- Kiểm chứng tính chất Idempotent của tiến trình Upsert:
-- Chạy thử nghiệm lệnh Upsert 3 lần liên tiếp với cùng một tập dữ liệu nguồn và chứng minh
-- trạng thái bảng đích và số lượng bản ghi hoàn toàn không bị sai lệch sau nhiều lần chạy lại.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.6.1 TẠI ĐÂY:

DROP TABLE IF EXISTS #idempotent_target;
DROP TABLE IF EXISTS #idempotent_source;
DROP TABLE IF EXISTS #run_audit;

CREATE TABLE #idempotent_target (
    customer_id   VARCHAR(50) PRIMARY KEY,
    customer_city NVARCHAR(200),
    updated_at    DATETIME2 DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE #idempotent_source (
    customer_id   VARCHAR(50),
    customer_city NVARCHAR(200)
);

CREATE TABLE #run_audit (
    run_no        INT,
    inserted_rows INT,
    updated_rows  INT,
    total_rows    INT
);

-- Nạp sẵn 1 dòng cũ ở đích và 2 dòng ở nguồn (1 dòng giữ nguyên, 1 dòng mới)
INSERT INTO #idempotent_target (customer_id, customer_city) VALUES ('CUST_001', N'sao paulo');
INSERT INTO #idempotent_source (customer_id, customer_city) VALUES ('CUST_001', N'sao paulo'), ('CUST_002', N'rio de janeiro');

DECLARE @run INT = 1;
WHILE @run <= 3
BEGIN
    DECLARE @act TABLE (action_type VARCHAR(10));
    DELETE FROM @act;

    MERGE INTO #idempotent_target AS tgt
    USING #idempotent_source AS src
        ON tgt.customer_id = src.customer_id
    WHEN MATCHED AND ISNULL(tgt.customer_city, '') <> ISNULL(src.customer_city, '') THEN
        UPDATE SET tgt.customer_city = src.customer_city, tgt.updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (customer_id, customer_city) VALUES (src.customer_id, src.customer_city)
    OUTPUT $action INTO @act;

    INSERT INTO #run_audit (run_no, inserted_rows, updated_rows, total_rows)
    SELECT
        @run,
        SUM(CASE WHEN action_type = 'INSERT' THEN 1 ELSE 0 END),
        SUM(CASE WHEN action_type = 'UPDATE' THEN 1 ELSE 0 END),
        (SELECT COUNT(*) FROM #idempotent_target)
    FROM @act;

    SET @run += 1;
END;

-- Kết quả kỳ vọng: Lần 1 chèn 1 dòng (total=2); Lần 2 và Lần 3 có inserted=0, updated=0, total giữ nguyên=2!
SELECT
    run_no,
    ISNULL(inserted_rows, 0) AS inserted_rows,
    ISNULL(updated_rows, 0)  AS updated_rows,
    total_rows
FROM #run_audit
ORDER BY run_no;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu pipeline không có tính Idempotent (ví dụ dùng INSERT thuần không kiểm tra tồn tại, hoặc UPDATE không có điều kiện khác biệt),
--      khi Airflow/ADF tự chạy lại (retry) sau sự cố mạng sẽ làm nhân đôi dữ liệu (Double Counting),
--      nổ lỗi Duplicate Key hoặc ghi đè sai dấu thời gian updated_at dù dữ liệu không hề đổi.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Chạy lại 1 lần hay 3 lần liên tiếp đều cho trạng thái bảng đích giống hệt nhau (total_rows không đổi),
--      lần chạy lại sau không ghi đĩa dư thừa (0 INSERT, 0 UPDATE), an toàn tuyệt đối khi retry pipeline.



-- ------------------------------------------------------------------------------------------
-- Câu 2.6.2:
-- Áp dụng cơ chế khóa an toàn (Locking Hints) trong quy trình Upsert
-- nhằm ngăn chặn lỗi Deadlock hoặc xung đột khi có nhiều tiến trình nạp dữ liệu cùng lúc.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.6.2 TẠI ĐÂY:

SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

        -- Dùng WITH (UPDLOCK, HOLDLOCK) trong giao dịch:
        -- + UPDLOCK: Lấy khóa cập nhật ngay từ lúc kiểm tra tồn tại -> tránh 2 session cùng đọc rồi cùng nâng cấp lên X-Lock gây Deadlock.
        -- + HOLDLOCK (tương đương SERIALIZABLE range lock): Giữ khóa dải khóa cho tới hết Transaction -> chặn session khác chèn trùng khóa giữa lúc kiểm tra và INSERT.
        MERGE INTO dbo.dim_customers_soft_delete WITH (UPDLOCK, HOLDLOCK) AS tgt
        USING (
            SELECT TOP (100)
                customer_id,
                customer_unique_id,
                customer_zip_code_prefix,
                customer_city,
                customer_state
            FROM dbo.olist_customers_dataset
        ) AS src
            ON tgt.customer_id = src.customer_id
        WHEN MATCHED AND EXISTS (
            SELECT src.customer_zip_code_prefix, src.customer_city, src.customer_state
            EXCEPT
            SELECT tgt.customer_zip_code_prefix, tgt.customer_city, tgt.customer_state
        ) THEN
            UPDATE SET
                tgt.customer_zip_code_prefix = src.customer_zip_code_prefix,
                tgt.customer_city            = src.customer_city,
                tgt.customer_state           = src.customer_state,
                tgt.updated_at               = CURRENT_TIMESTAMP
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
            VALUES (src.customer_id, src.customer_unique_id, src.customer_zip_code_prefix, src.customer_city, src.customer_state);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Khi 2 tiến trình (worker/session) chạy MERGE hoặc Two-Step Upsert song song cho cùng tập khóa chưa tồn tại:
--      Cả 2 cùng đọc thấy "chưa có" rồi cùng lao vào INSERT -> sinh lỗi Primary Key Violation (2627),
--      hoặc cả 2 cùng giữ Shared Lock rồi chờ nâng cấp lên Exclusive Lock của nhau -> gây Deadlock (1205).
-- 2. Khi giải quyết xong thì như thế nào:
--    - Khóa UPDLOCK + HOLDLOCK tuần tự hóa quyền kiểm tra và ghi trên vùng khóa đang xử lý cho tới khi COMMIT,
--      triệt tiêu Race Condition và tránh lỗi trùng khóa chính / Deadlock chuyển đổi khóa khi chạy đồng thời.



-- ------------------------------------------------------------------------------------------
-- Câu 2.6.3:
-- Thiết kế kịch bản tự động khôi phục dữ liệu về trạng thái an toàn nếu lệnh Upsert bị ngắt kết nối đột ngột.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.6.3 TẠI ĐÂY:

-- SET XACT_ABORT ON là chìa khóa: ngay cả khi client ngắt kết nối (Attention / Timeout) hoặc lỗi mức Batch,
-- SQL Server lập tức tự động ROLLBACK toàn bộ giao dịch đang mở thay vì để treo Transaction giữ Lock!
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

        -- Khử trùng nguồn trước khi nạp
        WITH dedup_src AS (
            SELECT
                customer_id,
                customer_unique_id,
                customer_zip_code_prefix,
                customer_city,
                customer_state,
                ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_id) AS rn
            FROM (
                SELECT TOP (200)
                    customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state
                FROM dbo.olist_customers_dataset
            ) raw_batch
        )
        MERGE INTO dbo.dim_customers_soft_delete WITH (UPDLOCK, HOLDLOCK) AS tgt
        USING (SELECT * FROM dedup_src WHERE rn = 1) AS src
            ON tgt.customer_id = src.customer_id
        WHEN MATCHED AND EXISTS (
            SELECT src.customer_city, src.customer_state
            EXCEPT
            SELECT tgt.customer_city, tgt.customer_state
        ) THEN
            UPDATE SET
                tgt.customer_city  = src.customer_city,
                tgt.customer_state = src.customer_state,
                tgt.updated_at     = CURRENT_TIMESTAMP
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
            VALUES (src.customer_id, src.customer_unique_id, src.customer_zip_code_prefix, src.customer_city, src.customer_state);

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    -- Ghi nhận hoặc ném lỗi ra ngoài để công cụ điều phối kích hoạt retry sạch sẽ
    THROW;
END CATCH;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Mặc định SET XACT_ABORT là OFF: nếu mất kết nối giữa chừng hoặc gặp một số lỗi runtime giữa khối UPDATE và INSERT,
--      Transaction có thể không tự rollback triệt để -> để lại dữ liệu nửa vời (một nửa đã UPDATE, một nửa chưa INSERT)
--      hoặc làm phiên treo giữ Lock chặn toàn bộ hệ thống.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Kết hợp SET XACT_ABORT ON với TRY/CATCH + XACT_STATE() đảm bảo 100% trường hợp lỗi hoặc đứt kết nối đều tự động rollback sạch về trạng thái trước lúc chạy,
--      giải phóng toàn bộ Lock và sẵn sàng cho lần chạy bù (retry) an toàn.



-- ------------------------------------------------------------------------------------------
-- [P2 - NGÀY 7]: ĐÓNG GÓI STORED PROCEDURE UPSERT CHUẨN PRODUCTION
-- ------------------------------------------------------------------------------------------

-- Câu 2.7.1:
-- Xây dựng Stored Procedure `usp_Upsert_Dim_Customers`:
-- Nhận dữ liệu từ Staging, thực hiện đồng bộ Upsert vào bảng Dimension khách hàng
-- và ghi nhận lịch sử số lượng bản ghi bị tác động vào bảng Audit Log.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.7.1 TẠI ĐÂY:

-- Chuẩn bị bảng Audit Log cho tiến trình Upsert (nếu chưa có)
IF OBJECT_ID('stg.upsert_audit_log', 'U') IS NULL
BEGIN
    CREATE TABLE stg.upsert_audit_log (
        audit_id       INT IDENTITY(1,1) PRIMARY KEY,
        procedure_name VARCHAR(100),
        target_table   VARCHAR(100),
        inserted_rows  INT,
        updated_rows   INT,
        status         VARCHAR(20),
        error_message  NVARCHAR(MAX) NULL,
        executed_at    DATETIME2 NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Upsert_Dim_Customers
    @SourceBatchSize INT = NULL -- Cho phép giới hạn batch khi test, NULL = lấy toàn bộ nguồn
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @inserted_cnt INT = 0;
    DECLARE @updated_cnt  INT = 0;
    DECLARE @merge_actions TABLE (action_type VARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            WITH src_dedup AS (
                SELECT
                    customer_id,
                    customer_unique_id,
                    customer_zip_code_prefix,
                    UPPER(TRIM(customer_city))  AS customer_city,
                    UPPER(TRIM(customer_state)) AS customer_state,
                    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_id) AS rn
                FROM dbo.olist_customers_dataset
                WHERE customer_id IS NOT NULL
            )
            MERGE INTO dbo.dim_customers_soft_delete WITH (UPDLOCK, HOLDLOCK) AS tgt
            USING (
                SELECT TOP (ISNULL(@SourceBatchSize, 2147483647))
                    customer_id,
                    customer_unique_id,
                    customer_zip_code_prefix,
                    customer_city,
                    customer_state
                FROM src_dedup
                WHERE rn = 1
                ORDER BY customer_id
            ) AS src
                ON tgt.customer_id = src.customer_id
            WHEN MATCHED AND (
                tgt.is_deleted = 1
                OR EXISTS (
                    SELECT src.customer_zip_code_prefix, src.customer_city, src.customer_state
                    EXCEPT
                    SELECT tgt.customer_zip_code_prefix, tgt.customer_city, tgt.customer_state
                )
            ) THEN
                UPDATE SET
                    tgt.customer_zip_code_prefix = src.customer_zip_code_prefix,
                    tgt.customer_city            = src.customer_city,
                    tgt.customer_state           = src.customer_state,
                    tgt.is_deleted               = 0,
                    tgt.deleted_at               = NULL,
                    tgt.updated_at               = CURRENT_TIMESTAMP
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, customer_state)
                VALUES (src.customer_id, src.customer_unique_id, src.customer_zip_code_prefix, src.customer_city, src.customer_state)
            OUTPUT $action INTO @merge_actions;

            SELECT
                @inserted_cnt = ISNULL(SUM(CASE WHEN action_type = 'INSERT' THEN 1 ELSE 0 END), 0),
                @updated_cnt  = ISNULL(SUM(CASE WHEN action_type = 'UPDATE' THEN 1 ELSE 0 END), 0)
            FROM @merge_actions;

            INSERT INTO stg.upsert_audit_log (procedure_name, target_table, inserted_rows, updated_rows, status)
            VALUES ('dbo.usp_Upsert_Dim_Customers', 'dbo.dim_customers_soft_delete', @inserted_cnt, @updated_cnt, 'SUCCESS');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO stg.upsert_audit_log (procedure_name, target_table, inserted_rows, updated_rows, status, error_message)
        VALUES ('dbo.usp_Upsert_Dim_Customers', 'dbo.dim_customers_soft_delete', 0, 0, 'FAILED', ERROR_MESSAGE());

        THROW;
    END CATCH;
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Logic Upsert nằm rải rác bằng câu SQL rời rạc khiến mỗi lần sửa nghiệp vụ phải dò nhiều chỗ, không tái sử dụng được Execution Plan,
--      và khi có sự cố không biết bao nhiêu dòng đã được chèn hay cập nhật trong mỗi lần chạy batch.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ quy trình khử trùng + chống Ghost Update + khóa an toàn + đếm số dòng INSERT/UPDATE qua OUTPUT $action + ghi nhật ký Audit Log
--      được đóng gói chuẩn hóa thành 1 Stored Procedure duy nhất, dễ giám sát và vận hành trên Production.



-- ------------------------------------------------------------------------------------------
-- Câu 2.7.2:
-- Xây dựng Stored Procedure `usp_Upsert_Fact_Orders`:
-- Thực hiện đồng bộ trạng thái đơn hàng và các mốc thời gian giao nhận vào bảng Fact bán hàng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.7.2 TẠI ĐÂY:

GO
CREATE OR ALTER PROCEDURE dbo.usp_Upsert_Fact_Orders
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @inserted_cnt INT = 0;
    DECLARE @updated_cnt  INT = 0;
    DECLARE @merge_actions TABLE (action_type VARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            WITH stg_orders_dedup AS (
                SELECT
                    order_id,
                    customer_id,
                    order_status,
                    order_purchase_timestamp,
                    order_approved_at,
                    order_delivered_carrier_date,
                    order_delivered_customer_date,
                    order_estimated_delivery_date,
                    ROW_NUMBER() OVER (
                        PARTITION BY order_id
                        ORDER BY COALESCE(order_delivered_customer_date, order_delivered_carrier_date, order_approved_at, order_purchase_timestamp) DESC
                    ) AS rn
                FROM stg.stg_orders
                WHERE order_id IS NOT NULL
            )
            MERGE INTO dbo.olist_orders_dataset WITH (UPDLOCK, HOLDLOCK) AS tgt
            USING (SELECT * FROM stg_orders_dedup WHERE rn = 1) AS src
                ON tgt.order_id = src.order_id
            WHEN MATCHED AND EXISTS (
                SELECT src.order_status, src.order_approved_at, src.order_delivered_carrier_date, src.order_delivered_customer_date, src.order_estimated_delivery_date
                EXCEPT
                SELECT tgt.order_status, tgt.order_approved_at, tgt.order_delivered_carrier_date, tgt.order_delivered_customer_date, tgt.order_estimated_delivery_date
            ) THEN
                UPDATE SET
                    tgt.order_status                  = src.order_status,
                    tgt.order_approved_at             = src.order_approved_at,
                    tgt.order_delivered_carrier_date  = src.order_delivered_carrier_date,
                    tgt.order_delivered_customer_date = src.order_delivered_customer_date,
                    tgt.order_estimated_delivery_date = src.order_estimated_delivery_date
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    order_id, customer_id, order_status, order_purchase_timestamp,
                    order_approved_at, order_delivered_carrier_date, order_delivered_customer_date, order_estimated_delivery_date
                )
                VALUES (
                    src.order_id, src.customer_id, src.order_status, src.order_purchase_timestamp,
                    src.order_approved_at, src.order_delivered_carrier_date, src.order_delivered_customer_date, src.order_estimated_delivery_date
                )
            OUTPUT $action INTO @merge_actions;

            SELECT
                @inserted_cnt = ISNULL(SUM(CASE WHEN action_type = 'INSERT' THEN 1 ELSE 0 END), 0),
                @updated_cnt  = ISNULL(SUM(CASE WHEN action_type = 'UPDATE' THEN 1 ELSE 0 END), 0)
            FROM @merge_actions;

            INSERT INTO stg.upsert_audit_log (procedure_name, target_table, inserted_rows, updated_rows, status)
            VALUES ('dbo.usp_Upsert_Fact_Orders', 'dbo.olist_orders_dataset', @inserted_cnt, @updated_cnt, 'SUCCESS');

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO stg.upsert_audit_log (procedure_name, target_table, inserted_rows, updated_rows, status, error_message)
        VALUES ('dbo.usp_Upsert_Fact_Orders', 'dbo.olist_orders_dataset', 0, 0, 'FAILED', ERROR_MESSAGE());

        THROW;
    END CATCH;
END;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Các đơn hàng thay đổi trạng thái (từ 'shipped' -> 'delivered') hoặc cập nhật ngày giao hàng thực tế sẽ không được đồng bộ sang Fact nếu chỉ chèn mới;
--      ngược lại nếu cập nhật toàn bộ không dùng EXCEPT sẽ gây ghi đè hàng loạt làm nghẽn Transaction Log và sai dữ liệu khi Staging bị trùng khóa.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ quy trình khử trùng Staging -> đồng bộ chính xác cả INSERT đơn mới lẫn UPDATE đơn đổi trạng thái/mốc giao hàng -> ghi Audit Log
--      diễn ra nguyên tử trong 1 Transaction an toàn, sẵn sàng cho Airflow/ADF gọi định kỳ.



-- ------------------------------------------------------------------------------------------
-- Câu 2.7.3:
-- Viết kịch bản kiểm thử tự động (Automated Test Case) cho Stored Procedure Upsert:
-- Chuẩn bị tập dữ liệu giả lập chứa cả 3 trường hợp: bản ghi chèn mới, bản ghi cập nhật, và bản ghi giữ nguyên,
-- sau đó xác minh kết quả sau khi thực thi Stored Procedure.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 2.7.3 TẠI ĐÂY:

-- Tạo Stored Procedure kiểm thử dùng bảng giả lập cô lập hoàn toàn để không làm bẩn dữ liệu thật
GO
CREATE OR ALTER PROCEDURE dbo.usp_Test_Upsert_Customer_Logic
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #test_target;
    DROP TABLE IF EXISTS #test_staging;

    CREATE TABLE #test_target (
        customer_id   VARCHAR(50) PRIMARY KEY,
        customer_city NVARCHAR(200),
        updated_at    DATETIME2 NOT NULL
    );

    CREATE TABLE #test_staging (
        customer_id   VARCHAR(50),
        customer_city NVARCHAR(200)
    );

    -- 1. Chuẩn bị trạng thái đích ban đầu (mốc thời gian cũ 2026-01-01)
    INSERT INTO #test_target (customer_id, customer_city, updated_at) VALUES
    ('TEST_KEEP',   N'sao paulo', '2026-01-01'), -- Case 1: Giữ nguyên (không đổi)
    ('TEST_UPDATE', N'curitiba',  '2026-01-01'); -- Case 2: Sẽ cập nhật thành phố mới

    -- 2. Chuẩn bị tập Staging giả lập đủ cả 3 kịch bản
    INSERT INTO #test_staging (customer_id, customer_city) VALUES
    ('TEST_KEEP',   N'sao paulo'), -- Giống hệt đích -> KHÔNG được UPDATE (chống Ghost Update)
    ('TEST_UPDATE', N'campinas'),  -- Đổi thành phố -> PHẢI UPDATE
    ('TEST_INSERT', N'salvador');  -- Mới tinh -> PHẢI INSERT

    -- 3. Thực thi logic MERGE giống Production và bắt hành động thực tế
    DECLARE @act TABLE (action_type VARCHAR(10), customer_id VARCHAR(50));

    MERGE INTO #test_target AS tgt
    USING #test_staging AS src
        ON tgt.customer_id = src.customer_id
    WHEN MATCHED AND ISNULL(tgt.customer_city, '') <> ISNULL(src.customer_city, '') THEN
        UPDATE SET tgt.customer_city = src.customer_city, tgt.updated_at = CURRENT_TIMESTAMP
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (customer_id, customer_city, updated_at) VALUES (src.customer_id, src.customer_city, CURRENT_TIMESTAMP)
    OUTPUT $action, inserted.customer_id INTO @act;

    -- 4. Khẳng định tự động (Assertions): Kiểm tra cả số dòng lẫn dữ liệu từng kịch bản
    DECLARE @ins INT = (SELECT COUNT(*) FROM @act WHERE action_type = 'INSERT');
    DECLARE @upd INT = (SELECT COUNT(*) FROM @act WHERE action_type = 'UPDATE');
    DECLARE @tot INT = (SELECT COUNT(*) FROM #test_target);
    DECLARE @keep_ts DATETIME2 = (SELECT updated_at FROM #test_target WHERE customer_id = 'TEST_KEEP');
    DECLARE @upd_city NVARCHAR(200) = (SELECT customer_city FROM #test_target WHERE customer_id = 'TEST_UPDATE');

    SELECT
        @ins AS inserted_count,
        @upd AS updated_count,
        @tot AS final_target_rows,
        CASE
            WHEN @ins = 1
             AND @upd = 1
             AND @tot = 3
             AND @keep_ts = '2026-01-01'
             AND @upd_city = N'campinas'
            THEN N'PASS: Đạt chuẩn 3 kịch bản (1 Insert, 1 Update, 1 Unchanged không Ghost Update)'
            ELSE N'FAIL: Logic Upsert hoạt động sai lệch kỳ vọng'
        END AS test_result;
END;
GO

-- Chạy kiểm thử tự động:
EXEC dbo.usp_Test_Upsert_Customer_Logic;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Đẩy Stored Procedure lên Production mà chỉ kiểm tra bằng mắt hoặc chạy bừa trên dữ liệu thật rất dễ lọt lỗi âm thầm
--      (như Ghost Update làm ghi đè mất updated_at cũ, hoặc thiếu nhánh INSERT/UPDATE) gây sai lệch dữ liệu diện rộng trước khi kịp phát hiện.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Có bộ test tự động bao phủ cả 3 nhánh (Insert, Update, Unchanged) trên bảng tạm cô lập; chỉ cần chạy 1 lệnh EXEC
--      là xác nhận PASS/FAIL ngay lập tức trong quy trình CI/CD trước khi triển khai thật.
