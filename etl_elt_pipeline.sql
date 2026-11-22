-- ==========================================================================================
-- ████████████████████████████████████████████████████████████████████████████████████████
-- PHẦN 3: ETL / ELT END-TO-END QUERY (BIẾN ĐỔI LIÊN HOÀN TRONG 1 TRUY VẤN)
-- Luồng chuẩn: RAW → Extract → Clean → Transform → Validate → Dedup → Load
-- Mẫu: WITH cleaned AS (...), transformed AS (...), ranked AS (...), validated AS (...)
-- ████████████████████████████████████████████████████████████████████████████████████████
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 1]: KIẾN TRÚC CTE PHÂN TẦNG (LAYERED CTE PIPELINE)
-- ------------------------------------------------------------------------------------------

-- Câu 3.1.1:
-- Xây dựng một truy vấn biến đổi khép kín 3 tầng cho bảng khách hàng:
-- Tầng 1: Trích xuất các trường dữ liệu thô cần thiết.
-- Tầng 2: Làm sạch khoảng trắng thừa và chuẩn hóa viết hoa tên thành phố.
-- Tầng 3: Chuẩn hóa mã bưu chính về chuỗi 5 chữ số có số 0 ở đầu.
-- Xuất tập dữ liệu sạch sẵn sàng để nạp vào kho.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.1.1 TẠI ĐÂY:

WITH raw_customers AS (
    -- Tầng 1: Trích xuất dữ liệu thô
    SELECT
        customer_id,
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state
    FROM dbo.olist_customers_dataset
    WHERE customer_id IS NOT NULL
),
cleaned_customers AS (
    -- Tầng 2: Làm sạch khoảng trắng thừa & chuẩn hóa viết hoa thành phố, mã bang
    SELECT
        customer_id,
        customer_unique_id,
        customer_zip_code_prefix,
        UPPER(TRIM(ISNULL(customer_city, N'UNKNOWN'))) AS clean_city,
        UPPER(TRIM(ISNULL(customer_state, 'XX')))     AS clean_state
    FROM raw_customers
),
formatted_customers AS (
    -- Tầng 3: Chuẩn hóa mã bưu chính thành chuỗi đúng 5 ký tự có số 0 ở đầu (vd 1001 -> '01001')
    SELECT
        customer_id,
        customer_unique_id,
        RIGHT('00000' + CAST(ISNULL(customer_zip_code_prefix, 0) AS VARCHAR(10)), 5) AS formatted_zip_code,
        clean_city,
        clean_state
    FROM cleaned_customers
)
SELECT
    customer_id,
    customer_unique_id,
    formatted_zip_code,
    clean_city  AS customer_city,
    clean_state AS customer_state
FROM formatted_customers;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Viết các hàm xử lý lồng nhau chằng chịt trong 1 câu SELECT khiến query cực kỳ khó đọc, khó bảo trì;
--      mã bưu chính dạng số bị mất số 0 ở đầu (01001 thành 1001) và tên thành phố có khoảng trắng/viết hoa thường lẫn lộn làm GROUP BY bị tách thành nhiều nhóm ảo.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Luồng biến đổi được chia thành 3 tầng CTE mạch lạc (Extract -> Clean -> Format),
--      dữ liệu đầu ra đồng nhất định dạng chuẩn 5 chữ số cho mã bưu chính và sẵn sàng nạp sạch vào Data Warehouse.


-- ------------------------------------------------------------------------------------------
-- Câu 3.1.2:
-- Xây dựng truy vấn phân tầng 4 bước cho bảng đánh giá:
-- Trích xuất thô -> Xử lý nội dung nhận xét bị thiếu -> Khử trùng lặp chỉ lấy đánh giá mới nhất của mỗi đơn hàng -> Xuất tập dữ liệu đạt chuẩn.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.1.2 TẠI ĐÂY:

WITH raw_reviews AS (
    -- Bước 1: Trích xuất thô
    SELECT
        review_id,
        order_id,
        review_score,
        review_comment_title,
        review_comment_message,
        review_creation_date,
        review_answer_timestamp
    FROM dbo.olist_order_reviews_dataset
    WHERE order_id IS NOT NULL
),
cleaned_reviews AS (
    -- Bước 2: Xử lý giá trị NULL / khoảng trắng ở tiêu đề và nội dung nhận xét
    SELECT
        review_id,
        order_id,
        ISNULL(review_score, 0) AS review_score,
        COALESCE(NULLIF(TRIM(review_comment_title), N''), N'Không có tiêu đề')     AS clean_title,
        COALESCE(NULLIF(TRIM(review_comment_message), N''), N'Không có nhận xét') AS clean_message,
        review_creation_date,
        review_answer_timestamp
    FROM raw_reviews
),
ranked_reviews AS (
    -- Bước 3: Khử trùng lặp theo đơn hàng, ưu tiên đánh giá được tạo/trả lời mới nhất
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY review_creation_date DESC, review_answer_timestamp DESC, review_id DESC
        ) AS rn
    FROM cleaned_reviews
)
-- Bước 4: Xuất tập dữ liệu đánh giá đạt chuẩn (1 dòng duy nhất cho mỗi order_id)
SELECT
    review_id,
    order_id,
    review_score,
    clean_title   AS review_comment_title,
    clean_message AS review_comment_message,
    review_creation_date,
    review_answer_timestamp
FROM ranked_reviews
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nhiều đơn hàng có nhiều lượt đánh giá gây nổ dòng (Fan-out) khi JOIN với bảng đơn hàng ở các báo cáo downstream;
--      nhận xét trống/NULL làm lỗi giao diện hoặc sai tỷ lệ thống kê phản hồi khách hàng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ đánh giá thiếu nội dung được chuẩn hóa giá trị mặc định rõ ràng và mỗi đơn hàng chỉ giữ lại đúng 1 đánh giá mới nhất,
--      bảo đảm tính duy nhất 1-1 theo order_id.


-- ------------------------------------------------------------------------------------------
-- Câu 3.1.3:
-- Viết truy vấn chứng minh sự khác biệt trong mô hình ELT:
-- Đưa toàn bộ dữ liệu thô vào bảng tạm Staging trước, sau đó dùng 1 câu lệnh SQL biến đổi trực tiếp trong kho
-- thay vì biến đổi trên đường truyền.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.1.3 TẠI ĐÂY:

-- BƯỚC 1 (E - L: Extract & Load nguyên trạng dữ liệu thô vào Staging trong DB trước)
DROP TABLE IF EXISTS #raw_stg_orders;

SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    order_estimated_delivery_date
INTO #raw_stg_orders
FROM dbo.olist_orders_dataset;

-- BƯỚC 2 (T: Transform trực tiếp bên trong sức mạnh xử lý song song của SQL Server)
WITH transformed_in_warehouse AS (
    SELECT
        order_id,
        customer_id,
        UPPER(TRIM(order_status)) AS normalized_status,
        order_purchase_timestamp,
        DATEDIFF(DAY, order_purchase_timestamp, order_delivered_customer_date) AS actual_delivery_days,
        CASE
            WHEN order_delivered_customer_date IS NULL THEN 'PENDING'
            WHEN CAST(order_delivered_customer_date AS DATE) <= CAST(order_estimated_delivery_date AS DATE) THEN 'ON_TIME'
            ELSE 'LATE'
        END AS sla_status
    FROM #raw_stg_orders
    WHERE order_id IS NOT NULL
)
SELECT
    normalized_status,
    sla_status,
    COUNT(*) AS order_count,
    AVG(CAST(actual_delivery_days AS FLOAT)) AS avg_delivery_days
FROM transformed_in_warehouse
GROUP BY normalized_status, sla_status
ORDER BY order_count DESC;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Theo kiểu ETL truyền thống, nếu kéo 100k - hàng triệu dòng qua Python/NodeJS để xử lý từng dòng trên đường truyền rồi mới đẩy vào DB,
--      tốc độ cực chậm do nghẽn mạng, tốn RAM ở máy trung gian và mất dữ liệu thô nếu code biến đổi gặp lỗi giữa chừng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Mô hình ELT nạp nhanh dữ liệu thô vào tầng Staging trước rồi tận dụng chính Engine tối ưu hóa (Parallelism, Index, Hash/Stream Aggregate) của Database
--      để biến đổi hàng loạt theo tập hợp (Set-based) nhanh hơn gấp nhiều lần và dễ chạy lại biến đổi bất cứ lúc nào.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 2]: NHÚNG BƯỚC KIỂM THỬ TỰ ĐỘNG VÀO TRUY VẤN BIẾN ĐỔI (VALIDATION LAYER)
-- ------------------------------------------------------------------------------------------

-- Câu 3.2.1:
-- Tích hợp tầng kiểm tra hợp lệ thời gian (Validation Step) vào giữa pipeline CTE đơn hàng:
-- Phát hiện và đánh dấu các đơn hàng có ngày khách nhận diễn ra trước ngày đặt hàng
-- để loại bỏ khỏi luồng nạp dữ liệu sạch.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.2.1 TẠI ĐÂY:

WITH extracted_orders AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date,
        order_estimated_delivery_date
    FROM dbo.olist_orders_dataset
),
validated_timeline AS (
    SELECT
        *,
        CASE
            WHEN order_delivered_customer_date IS NOT NULL
             AND order_delivered_customer_date < order_purchase_timestamp THEN 0
            WHEN order_approved_at IS NOT NULL
             AND order_approved_at < order_purchase_timestamp THEN 0
            ELSE 1
        END AS is_valid_timeline
    FROM extracted_orders
)
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    is_valid_timeline
FROM validated_timeline
WHERE is_valid_timeline = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Các bản ghi bị lệch múi giờ hoặc lỗi hệ thống nguồn (ngày nhận < ngày đặt) lọt thẳng vào bảng Fact,
--      làm chỉ số thời gian giao hàng trung bình bị số âm vô lý và làm sai lệch báo cáo SLA.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Tầng Validation tự động gắn cờ và chặn mọi đơn hàng có chuỗi thời gian phi logic ngay trong luồng biến đổi,
--      đảm bảo các chỉ số thời gian giao hàng ở tầng sạch luôn tin cậy.


-- ------------------------------------------------------------------------------------------
-- Câu 3.2.2:
-- Nhúng bước kiểm tra tính toàn vẹn tham chiếu trực tiếp trong luồng biến đổi mặt hàng:
-- Tự động loại bỏ các mặt hàng bán ra có mã sản phẩm không tồn tại trong danh mục trước khi xuất kết quả.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.2.2 TẠI ĐÂY:

WITH raw_items AS (
    SELECT
        order_id,
        order_item_id,
        product_id,
        seller_id,
        shipping_limit_date,
        price,
        freight_value
    FROM dbo.olist_order_items_dataset
    WHERE price >= 0 AND freight_value >= 0
),
referential_checked AS (
    SELECT
        ri.*
    FROM raw_items ri
    WHERE EXISTS (
        -- Kiểm tra toàn vẹn tham chiếu tới danh mục sản phẩm chuẩn
        SELECT 1
        FROM dbo.olist_products_dataset p
        WHERE p.product_id = ri.product_id
    )
)
SELECT
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value
FROM referential_checked;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Các dòng mặt hàng mang product_id "mồ côi" (chưa có trong danh mục sản phẩm) khi nạp vào Data Warehouse
--      sẽ bị lỗi Foreign Key hoặc biến mất khi người dùng chạy INNER JOIN với Dim_Product -> gây lệch tổng doanh thu báo cáo.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Mệnh đề EXISTS (Left Semi Join) lọc bỏ triệt để các mặt hàng mồ côi trước khi nạp mà không làm nhân bản dòng như JOIN thông thường.


-- ------------------------------------------------------------------------------------------
-- Câu 3.2.3:
-- Kỹ thuật tách nhánh kết quả (Branching Output) trong cùng 1 truy vấn:
-- Một nhánh trích xuất các bản ghi hợp lệ để nạp kho, một nhánh tập hợp các bản ghi vi phạm quy tắc nghiệp vụ
-- kèm theo lý do lỗi cụ thể để ghi vào bảng cách ly.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.2.3 TẠI ĐÂY:

DROP TABLE IF EXISTS #clean_orders_stream;
DROP TABLE IF EXISTS #quarantine_orders;

-- Tạo bảng lưu kết quả đánh dấu quy tắc nghiệp vụ từ 1 lần quét duy nhất
DROP TABLE IF EXISTS #validated_batch;

WITH validation_rules AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        order_purchase_timestamp,
        order_delivered_customer_date,
        CASE
            WHEN order_id IS NULL THEN N'Thiếu khóa chính order_id'
            WHEN customer_id IS NULL THEN N'Thiếu khóa khách hàng customer_id'
            WHEN order_delivered_customer_date < order_purchase_timestamp THEN N'Lỗi thời gian: Ngày giao trước ngày đặt'
            WHEN order_status = 'delivered' AND order_delivered_customer_date IS NULL THEN N'Trạng thái delivered nhưng thiếu ngày giao hàng'
            ELSE NULL
        END AS error_reason
    FROM dbo.olist_orders_dataset
)
SELECT
    *,
    CASE WHEN error_reason IS NULL THEN 'VALID' ELSE 'INVALID' END AS validation_status
INTO #validated_batch
FROM validation_rules;

-- Nhánh 1: Dữ liệu hợp lệ sẵn sàng nạp kho
SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_delivered_customer_date
INTO #clean_orders_stream
FROM #validated_batch
WHERE validation_status = 'VALID';

-- Nhánh 2: Bản ghi vi phạm được cách ly kèm lý do lỗi chi tiết để xử lý hậu kiểm
SELECT order_id, customer_id, order_status, order_purchase_timestamp, order_delivered_customer_date, error_reason, CURRENT_TIMESTAMP AS quarantined_at
INTO #quarantine_orders
FROM #validated_batch
WHERE validation_status = 'INVALID';

-- Báo cáo kết quả phân luồng
SELECT
    (SELECT COUNT(*) FROM #clean_orders_stream) AS valid_rows_loaded,
    (SELECT COUNT(*) FROM #quarantine_orders)   AS quarantined_rows;

SELECT TOP (10) * FROM #quarantine_orders;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu chỉ dùng WHERE để lọc bỏ dòng lỗi, các bản ghi vi phạm biến mất trong im lặng (Silent Data Loss), không ai biết tại sao doanh thu thiếu;
--      còn nếu để cả dòng lỗi làm sập toàn bộ pipeline thì cả triệu dòng sạch cũng bị kẹt theo vài dòng rác.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Kỹ thuật Branching vừa cho phép luồng dữ liệu sạch tiếp tục chạy về kho bình thường,
--      vừa gom toàn bộ dòng lỗi vào bảng cách ly (Quarantine/Dead-Letter Table) kèm thông báo nguyên nhân rõ ràng để đội vận hành xử lý sau.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 3]: TÍCH HỢP KHỬ TRÙNG LẶP & ĐA TIÊU CHÍ VÀO LUỒNG BIẾN ĐỔI
-- ------------------------------------------------------------------------------------------

-- Câu 3.3.1:
-- Xây dựng chu trình hoàn chỉnh trong một câu truy vấn duy nhất:
-- Trích xuất đơn hàng thô -> Chuẩn hóa định dạng -> Gán số thứ tự phiên bản cập nhật ->
-- Lọc lấy bản ghi mới nhất của từng đơn -> Chèn trực tiếp vào bảng đích.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.3.1 TẠI ĐÂY:

DROP TABLE IF EXISTS #clean_target_orders;
CREATE TABLE #clean_target_orders (
    order_id                      VARCHAR(50) PRIMARY KEY,
    customer_id                   VARCHAR(50),
    order_status                  VARCHAR(50),
    order_purchase_timestamp      DATETIME2,
    order_delivered_customer_date DATETIME2,
    loaded_at                     DATETIME2 DEFAULT CURRENT_TIMESTAMP
);

WITH raw_extract AS (
    -- 1. Trích xuất thô
    SELECT
        order_id,
        customer_id,
        order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date
    FROM dbo.olist_orders_dataset
    WHERE order_id IS NOT NULL
),
standardized AS (
    -- 2. Chuẩn hóa định dạng
    SELECT
        TRIM(order_id)               AS order_id,
        TRIM(customer_id)            AS customer_id,
        LOWER(TRIM(order_status))    AS order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date
    FROM raw_extract
),
versioned AS (
    -- 3. Gán số thứ tự phiên bản cập nhật mới nhất theo từng đơn hàng
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY COALESCE(order_delivered_customer_date, order_delivered_carrier_date, order_approved_at, order_purchase_timestamp) DESC
        ) AS rn
    FROM standardized
)
-- 4 & 5. Lọc lấy bản ghi mới nhất (rn = 1) và chèn trực tiếp vào bảng đích
INSERT INTO #clean_target_orders (order_id, customer_id, order_status, order_purchase_timestamp, order_delivered_customer_date)
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date
FROM versioned
WHERE rn = 1;

SELECT COUNT(*) AS loaded_unique_orders FROM #clean_target_orders;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Chèn thẳng từ Staging vào bảng đích có Primary Key mà không trải qua bước chuẩn hóa và đánh số phiên bản
--      sẽ bị văng lỗi trùng khóa chính (Error 2627) ngay khi nguồn có bản ghi trùng lặp hoặc định dạng lộn xộn.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ quy trình Extract -> Standardize -> Deduplicate -> Load khép kín trong 1 truy vấn set-based duy nhất,
--      đảm bảo nạp vào đích đúng 1 phiên bản mới nhất cho mỗi đơn hàng mà không cần bảng trung gian rườm rà.


-- ------------------------------------------------------------------------------------------
-- Câu 3.3.2:
-- Khử trùng lặp đa nguồn kết hợp trong một truy vấn:
-- Khử trùng bảng Geolocation đưa về một tọa độ đại diện cho từng mã bưu chính,
-- sau đó nối làm giàu thông tin cho hồ sơ khách hàng mà không làm phát sinh thêm dòng trùng lặp nào.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.3.2 TẠI ĐÂY:

WITH geo_dedup AS (
    -- Gom 1 triệu dòng Geolocation về duy nhất 1 dòng tọa độ trung bình cho mỗi mã bưu chính
    SELECT
        geolocation_zip_code_prefix AS zip_code_prefix,
        AVG(CAST(geolocation_lat AS FLOAT)) AS avg_lat,
        AVG(CAST(geolocation_lng AS FLOAT)) AS avg_lng
    FROM dbo.olist_geolocation_dataset
    WHERE geolocation_zip_code_prefix IS NOT NULL
    GROUP BY geolocation_zip_code_prefix
)
SELECT
    c.customer_id,
    c.customer_unique_id,
    c.customer_zip_code_prefix,
    c.customer_city,
    c.customer_state,
    g.avg_lat AS latitude,
    g.avg_lng AS longitude
FROM dbo.olist_customers_dataset c
LEFT JOIN geo_dedup g
    ON c.customer_zip_code_prefix = g.zip_code_prefix;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Bảng olist_geolocation_dataset chứa tới ~1 triệu dòng với hàng chục đến hàng trăm tọa độ lặp cho 1 mã bưu chính.
--    - Nếu JOIN thẳng olist_customers_dataset (99k dòng) vào geolocation, dữ liệu khách hàng sẽ bị "nổ dòng" (Cartesian Fan-out) lên hàng triệu dòng sai lệch hoàn toàn!
-- 2. Khi giải quyết xong thì như thế nào:
--    - CTE geo_dedup nén 1 triệu dòng về đúng 1 dòng đại diện/mã bưu chính trước khi LEFT JOIN,
--      bảo toàn tuyệt đối đúng 99,441 dòng khách hàng mà vẫn làm giàu đầy đủ tọa độ địa lý (Lat/Lng).


-- ------------------------------------------------------------------------------------------
-- Câu 3.3.3:
-- Áp dụng cơ chế ưu tiên chất lượng bản ghi (Quality Tie-Breaker) trực tiếp trong tầng CTE khử trùng
-- trước khi chuyển giao dữ liệu sang bước tính toán tiếp theo.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.3.3 TẠI ĐÂY:

WITH scored_orders AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_customer_date,
        -- Tính điểm chất lượng độ đầy đủ thông tin (Quality Score) để làm Tie-Breaker
        (CASE WHEN order_status = 'delivered' THEN 10 ELSE 0 END)
        + (CASE WHEN order_delivered_customer_date IS NOT NULL THEN 4 ELSE 0 END)
        + (CASE WHEN order_approved_at IS NOT NULL THEN 2 ELSE 0 END) AS quality_score
    FROM dbo.olist_orders_dataset
    WHERE order_id IS NOT NULL
),
dedup_with_tiebreaker AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                quality_score DESC,               -- Ưu tiên 1: Bản ghi có chất lượng/độ đầy đủ cao nhất
                order_purchase_timestamp DESC     -- Ưu tiên 2 (Tie-Breaker): Mới nhất nếu điểm bằng nhau
        ) AS rn
    FROM scored_orders
)
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    quality_score
FROM dedup_with_tiebreaker
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Khi nguồn gửi 2 bản ghi trùng khóa có cùng mốc thời gian (hoặc ORDER BY theo ngày ngẫu nhiên),
--      SQL Server có thể chọn nhầm bản ghi bị thiếu ngày giao hàng thay vì bản ghi đầy đủ thông tin hơn.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Cơ chế Quality Tie-Breaker chấm điểm độ hoàn chỉnh trước rồi mới xét thời gian,
--      đảm bảo bản ghi đi tiếp vào tầng tính toán luôn là phiên bản sạch và đầy đủ nhất.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 4]: TẠO DATASET BÁN HÀNG TỔNG HỢP (SALES MART PIPELINE)
-- ------------------------------------------------------------------------------------------

-- Câu 3.4.1:
-- Viết một truy vấn liên hoàn biến đổi từ 4 bảng nguồn thô (Đơn hàng, Mặt hàng chi tiết, Thanh toán, Khách hàng)
-- để tạo ra một tập dữ liệu phân tích bán hàng sạch sẽ, bảo toàn đúng số lượng doanh thu và không bị nổ dòng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.4.1 TẠI ĐÂY:

WITH payment_agg AS (
    -- Tổng hợp thanh toán ở mức order_id TRƯỚC khi JOIN để chống nổ dòng (1 đơn có thể trả bằng nhiều thẻ/voucher)
    SELECT
        order_id,
        SUM(payment_value) AS total_order_payment,
        MAX(payment_type)  AS primary_payment_type,
        COUNT(*)           AS payment_count
    FROM dbo.olist_order_payments_dataset
    GROUP BY order_id
),
order_items_agg AS (
    -- Tổng hợp doanh thu mặt hàng ở mức order_id để bảo toàn Grain 1 dòng / đơn hàng ở Sales Mart cấp đơn
    SELECT
        order_id,
        COUNT(*)           AS total_items,
        SUM(price)         AS total_item_price,
        SUM(freight_value) AS total_freight_value
    FROM dbo.olist_order_items_dataset
    GROUP BY order_id
)
SELECT
    o.order_id,
    c.customer_unique_id,
    UPPER(TRIM(c.customer_state))    AS customer_state,
    o.order_status,
    o.order_purchase_timestamp,
    ISNULL(oi.total_items, 0)        AS total_items,
    ISNULL(oi.total_item_price, 0)   AS total_item_price,
    ISNULL(oi.total_freight_value, 0) AS total_freight_value,
    ISNULL(p.total_order_payment, 0) AS total_order_payment,
    p.primary_payment_type
FROM dbo.olist_orders_dataset o
INNER JOIN dbo.olist_customers_dataset c
    ON o.customer_id = c.customer_id
LEFT JOIN order_items_agg oi
    ON o.order_id = oi.order_id
LEFT JOIN payment_agg p
    ON o.order_id = p.order_id
WHERE o.order_status <> 'canceled';
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu JOIN trực tiếp cả 2 bảng 1-N là olist_order_items_dataset (N món) và olist_order_payments_dataset (M lần trả) vào đơn hàng,
--      số dòng sẽ bị nhân chéo (N x M) làm tổng doanh thu và tổng tiền thanh toán bị cộng lặp gấp nhiều lần!
-- 2. Khi giải quyết xong thì như thế nào:
--    - Gom nhóm cả Items và Payments về đúng hạt nhân (Grain) của order_id trong CTE trước khi JOIN,
--      bảo toàn chính xác 100% doanh thu bán hàng và số lượng đơn hàng mà không bị nổ dòng.


-- ------------------------------------------------------------------------------------------
-- Câu 3.4.2:
-- Xử lý an toàn các phép tính tỷ trọng chi phí và phân bổ giá trị thanh toán
-- ngay trong tầng Transform của truy vấn bán hàng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.4.2 TẠI ĐÂY:

WITH payment_per_order AS (
    SELECT
        order_id,
        SUM(payment_value) AS total_order_payment
    FROM dbo.olist_order_payments_dataset
    GROUP BY order_id
),
item_enriched AS (
    SELECT
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.price,
        oi.freight_value,
        (oi.price + oi.freight_value) AS gross_item_amount,
        SUM(oi.price + oi.freight_value) OVER (PARTITION BY oi.order_id) AS order_gross_amount,
        ISNULL(p.total_order_payment, 0) AS total_order_payment
    FROM dbo.olist_order_items_dataset oi
    LEFT JOIN payment_per_order p
        ON oi.order_id = p.order_id
)
SELECT
    order_id,
    order_item_id,
    product_id,
    price,
    freight_value,
    -- Tỷ trọng cước phí trên tổng giá trị món hàng (an toàn chia cho 0 bằng NULLIF)
    ROUND(freight_value * 100.0 / NULLIF(gross_item_amount, 0), 2) AS freight_ratio_pct,
    -- Phân bổ tiền thanh toán của cả đơn xuống từng món hàng theo tỷ trọng giá trị
    ROUND(
        total_order_payment * (gross_item_amount * 1.0 / NULLIF(order_gross_amount, 0)),
        2
    ) AS allocated_payment_value
FROM item_enriched;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Gán nguyên giá trị thanh toán của cả đơn hàng vào từng món hàng sẽ làm tổng tiền bị nhân lên theo số lượng món;
--      phép chia tỷ lệ thiếu NULLIF sẽ làm sập toàn bộ truy vấn với lỗi "Divide by zero error encountered" khi gặp đơn hàng 0 đồng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Tiền thanh toán được phân bổ hợp lý xuống từng mặt hàng theo tỷ trọng giá trị đóng góp và bảo vệ phép chia bằng NULLIF,
--      giúp tổng tiền phân bổ khớp với tổng tiền thực thu ở cấp đơn hàng.


-- ------------------------------------------------------------------------------------------
-- Câu 3.4.3:
-- Tự động phân khúc quy mô đơn hàng (Order Tiering) và đánh giá cam kết thời gian giao hàng (SLA)
-- ngay tại tầng tính toán cuối cùng của pipeline bán hàng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.4.3 TẠI ĐÂY:

WITH order_values AS (
    SELECT
        o.order_id,
        o.order_status,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        ISNULL(SUM(oi.price + oi.freight_value), 0) AS order_total_value
    FROM dbo.olist_orders_dataset o
    LEFT JOIN dbo.olist_order_items_dataset oi
        ON o.order_id = oi.order_id
    GROUP BY
        o.order_id, o.order_status, o.order_purchase_timestamp,
        o.order_delivered_customer_date, o.order_estimated_delivery_date
)
SELECT
    order_id,
    order_status,
    order_total_value,
    CASE
        WHEN order_total_value >= 500 THEN 'VIP'
        WHEN order_total_value >= 200 THEN 'Large'
        WHEN order_total_value >= 50  THEN 'Medium'
        ELSE 'Small'
    END AS order_tier,
    CASE
        WHEN order_status <> 'delivered' OR order_delivered_customer_date IS NULL THEN 'Not Delivered'
        WHEN CAST(order_delivered_customer_date AS DATE) <= CAST(order_estimated_delivery_date AS DATE) THEN 'On-Time SLA'
        ELSE 'Breached SLA (Late)'
    END AS delivery_sla_status
FROM order_values;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Dữ liệu thô chỉ chứa các con số rời rạc (giá, ngày giao, ngày dự kiến); tầng BI/Dashboard phải tự tính công thức rải rác trên từng biểu đồ
--      gây nặng máy người dùng và dễ sai lệch định nghĩa giữa các phòng ban.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Các cột nghiệp vụ chuẩn hóa (order_tier, delivery_sla_status) được tính sẵn ngay tại tầng Transform cuối cùng,
--      giúp mọi báo cáo quản trị dùng chung 1 thước đo thống nhất và lọc/nhóm cực nhanh.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 5]: TẠO DATASET HỒ SƠ KHÁCH HÀNG TOÀN CẢNH (CUSTOMER 360 PIPELINE)
-- ------------------------------------------------------------------------------------------

-- Câu 3.5.1:
-- Viết truy vấn ELT một bước tổng hợp toàn bộ lịch sử của từng khách hàng:
-- Địa chỉ cập nhật mới nhất, ngày mua đầu, ngày mua cuối, tổng số đơn hàng đã hoàn tất và tổng giá trị chi tiêu trọn đời.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.5.1 TẠI ĐÂY:

WITH order_revenue AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        UPPER(TRIM(c.customer_city))  AS customer_city,
        UPPER(TRIM(c.customer_state)) AS customer_state,
        o.order_status,
        o.order_purchase_timestamp,
        ISNULL(SUM(oi.price + oi.freight_value), 0) AS order_amount
    FROM dbo.olist_orders_dataset o
    INNER JOIN dbo.olist_customers_dataset c
        ON o.customer_id = c.customer_id
    LEFT JOIN dbo.olist_order_items_dataset oi
        ON o.order_id = oi.order_id
    GROUP BY
        o.order_id, c.customer_unique_id, c.customer_city, c.customer_state,
        o.order_status, o.order_purchase_timestamp
),
latest_address AS (
    SELECT
        customer_unique_id,
        customer_city,
        customer_state,
        ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp DESC) AS rn
    FROM order_revenue
)
SELECT
    r.customer_unique_id,
    MAX(la.customer_city)  AS latest_city,
    MAX(la.customer_state) AS latest_state,
    MIN(r.order_purchase_timestamp) AS first_order_date,
    MAX(r.order_purchase_timestamp) AS last_order_date,
    COUNT(CASE WHEN r.order_status = 'delivered' THEN 1 END) AS completed_orders,
    SUM(CASE WHEN r.order_status = 'delivered' THEN r.order_amount ELSE 0 END) AS lifetime_value
FROM order_revenue r
INNER JOIN latest_address la
    ON r.customer_unique_id = la.customer_unique_id AND la.rn = 1
GROUP BY r.customer_unique_id;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Trong dữ liệu Olist, mỗi lần mua khách hàng có một customer_id mới nhưng dùng chung customer_unique_id;
--      nếu gom nhóm theo customer_id sẽ tưởng mỗi khách chỉ mua 1 đơn và mất toàn bộ lịch sử mua lặp lại.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ lịch sử mua hàng, địa chỉ cập nhật mới nhất và tổng chi tiêu trọn đời (LTV) được hợp nhất về đúng 1 dòng duy nhất cho mỗi customer_unique_id.


-- ------------------------------------------------------------------------------------------
-- Câu 3.5.2:
-- Tích hợp tầng phân nhóm RFM (Recency, Frequency, Monetary) trực tiếp trong truy vấn tổng hợp hồ sơ khách hàng.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.5.2 TẠI ĐÂY:

WITH customer_base AS (
    SELECT
        c.customer_unique_id,
        MAX(o.order_purchase_timestamp) AS last_order_date,
        COUNT(DISTINCT o.order_id)      AS frequency,
        ISNULL(SUM(oi.price + oi.freight_value), 0) AS monetary
    FROM dbo.olist_customers_dataset c
    INNER JOIN dbo.olist_orders_dataset o
        ON c.customer_id = o.customer_id
    LEFT JOIN dbo.olist_order_items_dataset oi
        ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
ref_date AS (
    SELECT MAX(last_order_date) AS snapshot_date FROM customer_base
),
rfm_metrics AS (
    SELECT
        cb.customer_unique_id,
        DATEDIFF(DAY, cb.last_order_date, rd.snapshot_date) AS recency_days,
        cb.frequency,
        cb.monetary
    FROM customer_base cb
    CROSS JOIN ref_date rd
),
rfm_scores AS (
    SELECT
        *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score, -- Mới mua gần đây -> điểm cao (5)
        NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score, -- Mua nhiều lần -> điểm cao (5)
        NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score  -- Chi tiêu cao -> điểm cao (5)
    FROM rfm_metrics
)
SELECT
    customer_unique_id,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    CONCAT(r_score, f_score, m_score) AS rfm_segment_code
FROM rfm_scores;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Đội Marketing không phân biệt được đâu là khách hàng VIP mới mua với khách hàng đã lâu không quay lại,
--      dẫn tới chạy chiến dịch khuyến mãi dàn trải gây tốn kém ngân sách.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Mỗi khách hàng được chấm sẵn bộ 3 chỉ số R-F-M (thang 1-5) ngay trong 1 luồng ELT bằng Window Function NTILE(5),
--      sẵn sàng lọc nhóm khách hàng mục tiêu (vd '555' VIP hoặc '155' khách cũ chi tiêu cao sắp rời bỏ).


-- ------------------------------------------------------------------------------------------
-- Câu 3.5.3:
-- Tính toán khoảng thời gian mua sắm trung bình giữa các đơn hàng và gắn nhãn phân loại khách hàng
-- (khách hàng mới, khách trung thành, hoặc khách có dấu hiệu rời bỏ).
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.5.3 TẠI ĐÂY:

WITH customer_history AS (
    SELECT
        c.customer_unique_id,
        MIN(o.order_purchase_timestamp) AS first_order_date,
        MAX(o.order_purchase_timestamp) AS last_order_date,
        COUNT(DISTINCT o.order_id)      AS total_orders
    FROM dbo.olist_customers_dataset c
    INNER JOIN dbo.olist_orders_dataset o
        ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
max_snapshot AS (
    SELECT MAX(last_order_date) AS max_date FROM customer_history
)
SELECT
    ch.customer_unique_id,
    ch.total_orders,
    ch.first_order_date,
    ch.last_order_date,
    DATEDIFF(DAY, ch.last_order_date, ms.max_date) AS days_since_last_order,
    CASE
        WHEN ch.total_orders > 1
            THEN CAST(DATEDIFF(DAY, ch.first_order_date, ch.last_order_date) * 1.0 / (ch.total_orders - 1) AS DECIMAL(10, 2))
        ELSE NULL
    END AS avg_days_between_orders,
    CASE
        WHEN DATEDIFF(DAY, ch.last_order_date, ms.max_date) > 180 THEN N'Có dấu hiệu rời bỏ (At-Risk / Churned)'
        WHEN ch.total_orders >= 2                                 THEN N'Khách trung thành (Loyal)'
        ELSE N'Khách hàng mới / Mua 1 lần (New)'
    END AS customer_lifecycle_label
FROM customer_history ch
CROSS JOIN max_snapshot ms;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Chia trực tiếp khoảng ngày cho (total_orders - 1) sẽ bị lỗi chia cho 0 khi khách chỉ mua đúng 1 đơn;
--      không đo nhịp độ mua sắm sẽ không biết thời điểm vàng để gửi mã chăm sóc giữ chân khách hàng.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Xử lý an toàn trường hợp khách mới (total_orders = 1), tính chính xác chu kỳ quay lại mua hàng
--      và phân loại rõ 3 nhóm vòng đời khách hàng để triển khai tự động hóa CSKH.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 6]: CHUYỂN ĐỔI GIỮA BẢNG TẠM VÀ CTE KHI XỬ LÝ DỮ LIỆU LỚN
-- ------------------------------------------------------------------------------------------

-- Câu 3.6.1:
-- So sánh và chuyển đổi một truy vấn CTE phức tạp nhiều tầng sang chuỗi các bảng tạm (Temp Table Chaining)
-- có đánh Index hỗ trợ để tối ưu bộ nhớ và tránh nghẽn TempDB khi xử lý hàng triệu bản ghi.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.6.1 TẠI ĐÂY:

SET STATISTICS IO, TIME ON;

-- Cách tối ưu cho dữ liệu lớn: Temp Table Chaining + Clustered Index thay cho CTE lồng 5-6 tầng
DROP TABLE IF EXISTS #step1_delivered_orders;
DROP TABLE IF EXISTS #step2_order_items_agg;

-- Tầng 1: Lọc sớm dữ liệu đơn hàng hoàn tất ra bảng tạm + tạo Primary Key (Clustered Index trên order_id)
SELECT
    order_id,
    customer_id,
    order_purchase_timestamp
INTO #step1_delivered_orders
FROM dbo.olist_orders_dataset
WHERE order_status = 'delivered';

CREATE CLUSTERED INDEX IX_Temp_Step1_OrderId ON #step1_delivered_orders (order_id);

-- Tầng 2: Tổng hợp bảng Items ra bảng tạm thứ 2 + tạo Clustered Index trên order_id
SELECT
    order_id,
    COUNT(*)           AS item_cnt,
    SUM(price)         AS total_price,
    SUM(freight_value) AS total_freight
INTO #step2_order_items_agg
FROM dbo.olist_order_items_dataset
GROUP BY order_id;

CREATE CLUSTERED INDEX IX_Temp_Step2_OrderId ON #step2_order_items_agg (order_id);

-- Tầng 3: Join 2 bảng tạm đã sắp xếp sẵn theo order_id -> Merge Join cực nhanh, có Statistics chính xác, không tràn Memory Grant!
SELECT
    c.customer_state,
    COUNT(*)                  AS delivered_orders,
    SUM(i.total_price)        AS total_revenue,
    SUM(i.total_freight)      AS total_freight
FROM #step1_delivered_orders o
INNER JOIN #step2_order_items_agg i
    ON o.order_id = i.order_id
INNER JOIN dbo.olist_customers_dataset c
    ON o.customer_id = c.customer_id
GROUP BY c.customer_state
ORDER BY total_revenue DESC;

SET STATISTICS IO, TIME OFF;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - CTE chỉ là câu lệnh ảo (không lưu kết quả trung gian và không có Statistics riêng); khi nối 5-6 tầng CTE trên hàng triệu dòng,
--      Optimizer dễ ước lượng sai số dòng nghiêm trọng -> cấp RAM sai gây Sort/Hash Spill ra TempDB hoặc chạy lại nhiều lần cùng 1 CTE.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Chia thành chuỗi bảng tạm (#TempTable) có Statistics thực tế ở từng bước và đánh Clustered Index đúng khóa Join
--      giúp SQL Server chuyển sang Merge Join / Seek gọn nhẹ, giảm mạnh áp lực RAM và thời gian xử lý dữ liệu lớn.


-- ------------------------------------------------------------------------------------------
-- Câu 3.6.2:
-- Thực hiện kiểm toán số dòng (Row Count Audit) qua từng tầng biến đổi trung gian
-- để đảm bảo không bị rơi rụng dữ liệu ngoài ý muốn.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.6.2 TẠI ĐÂY:

DROP TABLE IF EXISTS #audit_row_counts;
CREATE TABLE #audit_row_counts (
    step_order INT,
    stage_name VARCHAR(100),
    row_cnt    BIGINT
);

-- Tầng nguồn
INSERT INTO #audit_row_counts
SELECT 1, '1_Raw_Orders', COUNT(*) FROM dbo.olist_orders_dataset;

-- Tầng lọc hợp lệ
DROP TABLE IF EXISTS #audit_valid_orders;
SELECT order_id, customer_id INTO #audit_valid_orders
FROM dbo.olist_orders_dataset WHERE order_status = 'delivered';

INSERT INTO #audit_row_counts
SELECT 2, '2_Delivered_Orders', COUNT(*) FROM #audit_valid_orders;

-- Tầng Join khách hàng (kiểm tra đảm bảo số dòng KHÔNG bị tụt hoặc nổ dòng so với tầng 2)
DROP TABLE IF EXISTS #audit_joined_customers;
SELECT o.order_id, c.customer_state INTO #audit_joined_customers
FROM #audit_valid_orders o
LEFT JOIN dbo.olist_customers_dataset c ON o.customer_id = c.customer_id;

INSERT INTO #audit_row_counts
SELECT 3, '3_Joined_Customers', COUNT(*) FROM #audit_joined_customers;

-- Hiển thị báo cáo đối soát tỷ lệ giữ lại qua từng tầng
SELECT
    step_order,
    stage_name,
    row_cnt,
    row_cnt - LAG(row_cnt) OVER (ORDER BY step_order) AS diff_from_prev_step
FROM #audit_row_counts
ORDER BY step_order;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Dùng nhầm INNER JOIN khi bảng chiều thiếu mã sẽ làm rơi mất hàng nghìn đơn hàng ở bước giữa mà không hề hay biết;
--      hoặc JOIN trùng khóa làm số dòng tăng vọt ở bước cuối gây sai số liệu báo cáo.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Kiểm toán số dòng từng tầng bằng bảng audit + hàm LAG giúp phát hiện ngay điểm rơi rụng hoặc nổ dòng (diff_from_prev_step bất thường)
--      để khoanh vùng sửa lỗi chính xác.


-- ------------------------------------------------------------------------------------------
-- Câu 3.6.3:
-- Áp dụng kỹ thuật đẩy sớm điều kiện lọc (Filter Pushdown) ngay tại tầng trích xuất đầu tiên
-- để giảm tải tối đa khối lượng dữ liệu truyền qua các bước sau.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.6.3 TẠI ĐÂY:

SET STATISTICS IO, TIME ON;

-- Filter Pushdown: Đưa điều kiện order_status = 'delivered' và khoảng ngày lên ngay bước đọc đầu tiên
-- (thay vì JOIN toàn bộ 99k đơn x 112k items x 103k thanh toán rồi mới lọc ở cuối!)
WITH filtered_orders AS (
    SELECT order_id, customer_id, order_purchase_timestamp
    FROM dbo.olist_orders_dataset
    WHERE order_status = 'delivered'
      AND order_purchase_timestamp >= '2018-01-01'
      AND order_purchase_timestamp <  '2018-02-01'
)
SELECT
    fo.order_id,
    fo.order_purchase_timestamp,
    COUNT(oi.order_item_id) AS item_count,
    SUM(oi.price)           AS total_price
FROM filtered_orders fo
INNER JOIN dbo.olist_order_items_dataset oi
    ON fo.order_id = oi.order_id
GROUP BY fo.order_id, fo.order_purchase_timestamp;

SET STATISTICS IO, TIME OFF;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Nếu thực hiện tính toán phức tạp (như Window Function toàn bảng, DISTINCT hoặc ép kiểu trên cột) trước rồi mới đặt WHERE ở ngoài cùng,
--      SQL Server bị chặn không đẩy được điều kiện lọc xuống tầng đọc bảng -> phải quét và ghép toàn bộ dữ liệu nhiều năm rồi mới vứt bỏ tới 90%.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Đẩy điều kiện lọc (Filter Pushdown) lên ngay tầng trích xuất đầu tiên giúp Index Seek đọc đúng tập dữ liệu nhỏ của tháng cần lấy,
--      giảm mạnh số dòng đi qua các bước JOIN và GROUP BY phía sau.



-- ------------------------------------------------------------------------------------------
-- [P3 - NGÀY 7]: ĐÓNG GÓI TOÀN BỘ THÀNH SILVER VIEWS & STORED PROCEDURE ELT
-- ------------------------------------------------------------------------------------------

-- Câu 3.7.1:
-- Đóng gói toàn bộ câu truy vấn biến đổi dữ liệu đơn hàng thành một View tầng Silver `v_silver_orders`
-- chuẩn hóa để tái sử dụng xuyên suốt toàn bộ dự án.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.7.1 TẠI ĐÂY:

GO
CREATE OR ALTER VIEW dbo.v_silver_orders AS
WITH dedup_orders AS (
    SELECT
        TRIM(order_id)            AS order_id,
        TRIM(customer_id)         AS customer_id,
        LOWER(TRIM(order_status)) AS order_status,
        order_purchase_timestamp,
        order_approved_at,
        order_delivered_carrier_date,
        order_delivered_customer_date,
        order_estimated_delivery_date,
        CASE
            WHEN order_delivered_customer_date IS NOT NULL
             AND CAST(order_delivered_customer_date AS DATE) <= CAST(order_estimated_delivery_date AS DATE) THEN 1
            ELSE 0
        END AS is_on_time_sla,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY COALESCE(order_delivered_customer_date, order_delivered_carrier_date, order_approved_at, order_purchase_timestamp) DESC
        ) AS rn
    FROM dbo.olist_orders_dataset
    WHERE order_id IS NOT NULL
      AND customer_id IS NOT NULL
      AND order_status IS NOT NULL
      AND (order_delivered_customer_date IS NULL OR order_delivered_customer_date >= order_purchase_timestamp)
)
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    is_on_time_sla
FROM dedup_orders
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Mỗi thành viên trong nhóm tự viết lại logic lọc NULL, chuẩn hóa chữ thường và khử trùng ở hàng chục truy vấn khác nhau;
--      khi quy tắc nghiệp vụ thay đổi (ví dụ thêm quy tắc kiểm tra ngày giao) phải đi sửa tay từng file rất dễ sót và không đồng nhất.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Logic làm sạch đơn hàng được đóng gói tập trung vào một lớp Silver View chuẩn duy nhất (`dbo.v_silver_orders`),
--      mọi báo cáo và tầng Gold/Fact chỉ cần SELECT từ View này là luôn nhận dữ liệu sạch, chuẩn hóa giống nhau.


-- ------------------------------------------------------------------------------------------
-- Câu 3.7.2:
-- Đóng gói truy vấn biến đổi hồ sơ khách hàng thành View tầng Silver `v_silver_customers`.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.7.2 TẠI ĐÂY:

GO
CREATE OR ALTER VIEW dbo.v_silver_customers AS
WITH dedup_customers AS (
    SELECT
        TRIM(customer_id)        AS customer_id,
        TRIM(customer_unique_id) AS customer_unique_id,
        RIGHT('00000' + CAST(ISNULL(customer_zip_code_prefix, 0) AS VARCHAR(10)), 5) AS zip_code_5digit,
        UPPER(TRIM(ISNULL(customer_city, N'UNKNOWN'))) AS customer_city,
        UPPER(TRIM(ISNULL(customer_state, 'XX')))     AS customer_state,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY customer_id) AS rn
    FROM dbo.olist_customers_dataset
    WHERE customer_id IS NOT NULL
      AND customer_unique_id IS NOT NULL
)
SELECT
    customer_id,
    customer_unique_id,
    zip_code_5digit,
    customer_city,
    customer_state
FROM dedup_customers
WHERE rn = 1;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Dữ liệu khách hàng chưa chuẩn hóa (tên thành phố lộn xộn hoa/thường, mã zip mất số 0 đầu) bị dùng trực tiếp ở các tầng trên
--      gây phân mảnh nhóm thống kê địa bàn và sai lệch khi nối với bảng địa điểm.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Tầng Silver `dbo.v_silver_customers` cung cấp giao diện dữ liệu khách hàng sạch, đồng bộ chuẩn 5 ký tự zip code
--      và sẵn sàng phục vụ đồng thời cả báo cáo nhanh lẫn nạp Dimension.


-- ------------------------------------------------------------------------------------------
-- Câu 3.7.3:
-- Viết Stored Procedure điều phối toàn bộ quy trình ELT:
-- Thực thi tuần tự các bước trích xuất, làm sạch, kiểm thử chất lượng, nạp dữ liệu đích và ghi nhật ký thời gian hoàn thành.
-- ------------------------------------------------------------------------------------------
-- VIẾT QUERY CÂU 3.7.3 TẠI ĐÂY:

-- Tạo bảng lưu nhật ký vận hành ELT Pipeline (nếu chưa có)
IF OBJECT_ID('dbo.elt_pipeline_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.elt_pipeline_log (
        log_id           INT IDENTITY(1,1) PRIMARY KEY,
        pipeline_name    VARCHAR(100),
        start_time       DATETIME2,
        end_time         DATETIME2,
        duration_ms      INT,
        valid_orders_cnt INT,
        quarantine_cnt   INT,
        status           VARCHAR(20),
        error_message    NVARCHAR(MAX) NULL
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Run_Silver_ELT_Pipeline
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @start_time DATETIME2 = CURRENT_TIMESTAMP;
    DECLARE @valid_cnt INT = 0;
    DECLARE @quarantine_cnt INT = 0;

    BEGIN TRY
        -- Bước 1: Tạo bảng đích Silver & Quarantine nếu chưa tồn tại
        IF OBJECT_ID('dbo.silver_orders_clean', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.silver_orders_clean (
                order_id                      VARCHAR(50) PRIMARY KEY,
                customer_id                   VARCHAR(50),
                order_status                  VARCHAR(50),
                order_purchase_timestamp      DATETIME2,
                order_delivered_customer_date DATETIME2,
                order_estimated_delivery_date DATETIME2,
                is_on_time_sla                BIT,
                ingested_at                   DATETIME2 DEFAULT CURRENT_TIMESTAMP
            );
        END;

        IF OBJECT_ID('dbo.silver_orders_quarantine', 'U') IS NULL
        BEGIN
            CREATE TABLE dbo.silver_orders_quarantine (
                order_id       VARCHAR(50),
                error_reason   NVARCHAR(200),
                quarantined_at DATETIME2 DEFAULT CURRENT_TIMESTAMP
            );
        END;

        BEGIN TRANSACTION;

            -- Bước 2: Đọc dữ liệu sạch từ Silver View và nạp Idempotent vào bảng vật lý
            MERGE INTO dbo.silver_orders_clean WITH (UPDLOCK, HOLDLOCK) AS tgt
            USING dbo.v_silver_orders AS src
                ON tgt.order_id = src.order_id
            WHEN MATCHED AND EXISTS (
                SELECT src.order_status, src.order_delivered_customer_date, src.is_on_time_sla
                EXCEPT
                SELECT tgt.order_status, tgt.order_delivered_customer_date, tgt.is_on_time_sla
            ) THEN
                UPDATE SET
                    tgt.order_status                  = src.order_status,
                    tgt.order_delivered_customer_date = src.order_delivered_customer_date,
                    tgt.is_on_time_sla                = src.is_on_time_sla,
                    tgt.ingested_at                   = CURRENT_TIMESTAMP
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    order_id, customer_id, order_status, order_purchase_timestamp,
                    order_delivered_customer_date, order_estimated_delivery_date, is_on_time_sla
                )
                VALUES (
                    src.order_id, src.customer_id, src.order_status, src.order_purchase_timestamp,
                    src.order_delivered_customer_date, src.order_estimated_delivery_date, src.is_on_time_sla
                );

            SET @valid_cnt = @@ROWCOUNT;

            -- Bước 3: Cách ly các bản ghi lỗi thời gian để hậu kiểm
            TRUNCATE TABLE dbo.silver_orders_quarantine;

            INSERT INTO dbo.silver_orders_quarantine (order_id, error_reason)
            SELECT
                order_id,
                N'Ngày giao hàng diễn ra trước ngày đặt hàng'
            FROM dbo.olist_orders_dataset
            WHERE order_delivered_customer_date IS NOT NULL
              AND order_delivered_customer_date < order_purchase_timestamp;

            SET @quarantine_cnt = @@ROWCOUNT;

        COMMIT TRANSACTION;

        -- Bước 4: Ghi nhật ký chạy thành công kèm tổng thời gian thực thi
        INSERT INTO dbo.elt_pipeline_log (
            pipeline_name, start_time, end_time, duration_ms, valid_orders_cnt, quarantine_cnt, status
        )
        VALUES (
            'dbo.usp_Run_Silver_ELT_Pipeline',
            @start_time,
            CURRENT_TIMESTAMP,
            DATEDIFF(MILLISECOND, @start_time, CURRENT_TIMESTAMP),
            @valid_cnt,
            @quarantine_cnt,
            'SUCCESS'
        );

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.elt_pipeline_log (
            pipeline_name, start_time, end_time, duration_ms, valid_orders_cnt, quarantine_cnt, status, error_message
        )
        VALUES (
            'dbo.usp_Run_Silver_ELT_Pipeline',
            @start_time,
            CURRENT_TIMESTAMP,
            DATEDIFF(MILLISECOND, @start_time, CURRENT_TIMESTAMP),
            0, 0, 'FAILED', ERROR_MESSAGE()
        );

        THROW;
    END CATCH;
END;
GO

-- Thực thi chạy thử Stored Procedure ELT:
-- EXEC dbo.usp_Run_Silver_ELT_Pipeline;
-- SELECT * FROM dbo.elt_pipeline_log;
GO

-- GHI CHÚ BÀI TOÁN & HIỆU QUẢ GIẢI PHÁP:
-- 1. Nếu không giải quyết thì chuyện gì xảy ra:
--    - Chạy thủ công từng đoạn script rời rạc rất dễ quên thứ tự phụ thuộc, không có cơ chế rollback khi lỗi giữa chừng
--      và hoàn toàn mù thông tin về thời gian chạy hay số lượng bản ghi bị cách ly qua các ngày.
-- 2. Khi giải quyết xong thì như thế nào:
--    - Toàn bộ quy trình ELT (Clean -> Validate -> Upsert Idempotent -> Quarantine -> Logging) được đóng gói trong 1 Stored Procedure duy nhất,
--      chỉ cần lập lịch chạy 1 lệnh EXEC là hệ thống tự vận hành an toàn và lưu đầy đủ lịch sử giám sát.
