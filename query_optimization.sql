USE yellow_tripdata;
GO

/* ============================================================================
   query_optimization.sql
   MỤC TIÊU: Biết đọc Execution Plan, thiết kế Index, viết điều kiện / JOIN /
             GROUP BY hiệu quả, hiểu nguyên nhân plan tệ (Statistics, Parameter
             Sniffing, Spill) và biết viết lại query KHÔNG đổi kết quả.
   Database: yellow_tripdata
     - dbo.yellow_tripdata   : 9.45 triệu dòng (HEAP) + 4 index IX_lab02_pax/dist/fare/tip
     - dbo.lab_yellow_trips  : 200,000 dòng chuẩn hóa (tạo ở phần 00_SETUP)
   CÁCH CHẠY: bật Actual Execution Plan, bôi đen và chạy TỪNG BƯỚC một.
   Thứ tự: 00 -> 01 -> ... -> 12. Các Bài sau dùng lại bảng/index tạo ở Bài trước.
   Số liệu "~3 reads", "~156k dòng"... lấy từ ghi chú gốc, máy bạn sẽ lệch chút.
============================================================================ */


/* ============================================================================
   00_SETUP — CHẠY 1 LẦN. Toàn bộ các Bài phía dưới dựa vào phần này.
============================================================================ */

-- 00.1 Bảng chuẩn hóa 200k dòng (bảng gốc lưu cột dạng VARCHAR(MAX) nên không đặt khóa Index được)
IF OBJECT_ID('dbo.lab_yellow_trips', 'U') IS NULL
BEGIN
    SELECT TOP (200000)
        IDENTITY(INT, 1, 1)                                     AS trip_id,
        CAST(ISNULL(vendor_name, 'UNK') AS VARCHAR(10))         AS vendor_name,
        ISNULL(TRY_CAST(Trip_Pickup_DateTime AS DATETIME2), '2009-01-01') AS pickup_datetime,
        CAST(ISNULL(Payment_Type, 'UNKNOWN') AS VARCHAR(20))    AS payment_type,
        CAST(ISNULL(Passenger_Count, 1) AS INT)                 AS passenger_count,
        CAST(ISNULL(Trip_Distance, 0) AS FLOAT)                 AS trip_distance,
        CAST(ISNULL(Fare_Amt, 0) AS DECIMAL(10, 2))             AS fare_amt,
        CAST(ISNULL(Tip_Amt, 0) AS DECIMAL(10, 2))              AS tip_amt,
        CAST(ISNULL(Tolls_Amt, 0) AS DECIMAL(10, 2))            AS tolls_amt,
        CAST(ISNULL(Total_Amt, 0) AS DECIMAL(10, 2))            AS total_amt
    INTO dbo.lab_yellow_trips
    FROM dbo.yellow_tripdata;

    ALTER TABLE dbo.lab_yellow_trips
        ADD CONSTRAINT PK_Lab_Yellow_Trips PRIMARY KEY CLUSTERED (trip_id);
END;
GO

-- 00.2 Bảng danh mục hãng xe (dùng cho Bài 5, 11, 12)
IF OBJECT_ID('dbo.lab_vendors', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.lab_vendors (
        vendor_name      VARCHAR(10) PRIMARY KEY,
        vendor_full_name NVARCHAR(100),
        commission_pct   DECIMAL(5, 2)
    );
    INSERT INTO dbo.lab_vendors VALUES
    ('CMT', N'Creative Mobile Technologies', 12.50),
    ('VTS', N'VeriFone Transportation Systems', 11.75),
    ('DDS', N'Digital Dispatch Systems', 13.00);
END;
GO

-- 00.3 Kiểm tra các index sẵn có trên bảng 9.45M dòng (cần cho Bài 2, 4, 6)
SELECT name FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.yellow_tripdata') AND name LIKE 'IX_lab02_%';
-- Phải thấy IX_lab02_pax, IX_lab02_dist, IX_lab02_fare, IX_lab02_tip. Thiếu thì Bài 2/4/6 sẽ cho kết quả khác.
GO

SET STATISTICS IO, TIME ON;
GO


/* ============================================================================
   BÀI 1: QUERY PROCESSING & B-TREE (CHỦ YẾU LÀ KHÁI NIỆM)
============================================================================ */
/*
   1. Query đi qua: Parse -> Bind -> Optimize -> Execute.
      Optimizer là COST-BASED: nó ước lượng số dòng (nhờ Statistics) rồi chọn plan
      có "chi phí" thấp nhất. Plan được cache để lần sau khỏi biên dịch lại.
      => Plan tệ gần như luôn xuất phát từ: (a) ước lượng số dòng sai, (b) không có
         index phù hợp, (c) viết điều kiện làm index mất tác dụng.

   2. Index = cây B-Tree: Root -> Intermediate -> Leaf. Seek đi từ Root xuống Leaf
      nên tốn số page ~ số tầng của cây (vài page), dù bảng có hàng triệu dòng.
      Scan thì đọc tuần tự toàn bộ page.

   3. Clustered index  = chính là bảng (Leaf chứa toàn bộ dòng), mỗi bảng 1 cái.
      Nonclustered index = cây riêng, Leaf chứa key + con trỏ về dòng thật
      (RID nếu bảng là Heap, Clustered key nếu bảng có Clustered Index).
*/

-- 1B. (Chỉ đọc) Seek theo PK: logical reads xấp xỉ số tầng của cây B-Tree, rất nhỏ
-- SELECT trip_id, vendor_name, total_amt
-- FROM dbo.lab_yellow_trips
-- WHERE trip_id = 12345;
-- GO


/* ============================================================================
   BÀI 2: ĐỌC EXECUTION PLAN, LOGICAL READS, SCAN vs SEEK vs LOOKUP (9.45M DÒNG)
   Nguyên tắc: đo bằng LOGICAL READS (số page 8KB), không nhìn đồng hồ bấm giờ.
============================================================================ */

-- 2A. Table Scan: cột chưa có index -> quét sạch ~214,980 pages (~1.68 GB)
SELECT COUNT(*) AS high_total_trips
FROM dbo.yellow_tripdata
WHERE Total_Amt >= 250;
GO

-- 2B. Index Seek sạch trên IX_lab02_fare: chỉ đọc vài page
SELECT COUNT(*) AS fare_200_count
FROM dbo.yellow_tripdata
WHERE Fare_Amt = 200;
GO

-- 2C. Index Seek + RID Lookup: SELECT thêm cột không nằm trong index
--     -> với mỗi dòng tìm được phải nhảy về Heap lấy cột còn thiếu (31 lần). Logical reads tăng.
--     Đây là lý do "SELECT *" thường làm index vô dụng.
SELECT vendor_name, Trip_Pickup_DateTime, Fare_Amt, Total_Amt
FROM dbo.yellow_tripdata
WHERE Fare_Amt = 200;
GO


/* ============================================================================
   BÀI 3: COMPOSITE INDEX, LEFTMOST PREFIX, COVERING INDEX (INCLUDE)
   Quy tắc thiết kế: cột lọc bằng '=' đứng TRƯỚC, cột lọc khoảng (>=, <) đứng SAU.
============================================================================ */

DROP INDEX IF EXISTS IX_Trips_Payment_Pickup ON dbo.lab_yellow_trips;
GO

-- 3A. Composite Index CHƯA covering
CREATE INDEX IX_Trips_Payment_Pickup
ON dbo.lab_yellow_trips (payment_type, pickup_datetime);
GO

-- 3B. Có cột đầu (payment_type) -> Index Seek, NHƯNG dính KEY LOOKUP để lấy vendor_name, fare_amt, total_amt
SELECT trip_id, vendor_name, pickup_datetime, fare_amt, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'Dispute'
  AND pickup_datetime >= '2009-01-01'
  AND pickup_datetime <  '2009-01-16';
GO

-- 3C. LEFTMOST PREFIX bị vi phạm: bỏ qua cột đầu, chỉ lọc cột thứ 2 -> không Seek hiệu quả được (Scan)
SELECT trip_id, vendor_name, pickup_datetime
FROM dbo.lab_yellow_trips
WHERE pickup_datetime >= '2009-01-15 00:00:00'
  AND pickup_datetime <  '2009-01-15 01:00:00';
GO

-- 3D. Nâng cấp thành COVERING INDEX: key giữ gọn, INCLUDE các cột chỉ để SELECT
DROP INDEX IF EXISTS IX_Trips_Payment_Pickup ON dbo.lab_yellow_trips;
GO

CREATE INDEX IX_Trips_Payment_Pickup
ON dbo.lab_yellow_trips (payment_type, pickup_datetime)
INCLUDE (vendor_name, fare_amt, total_amt);
GO

-- 3E. Chạy lại đúng câu 3B: Key Lookup biến mất, chỉ còn Index Seek, logical reads tụt xuống vài page
SELECT trip_id, vendor_name, pickup_datetime, fare_amt, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'Dispute'
  AND pickup_datetime >= '2009-01-01'
  AND pickup_datetime <  '2009-01-16';
GO
-- Lưu ý: index càng nhiều/càng rộng thì INSERT/UPDATE/bulk load càng chậm. Đừng INCLUDE bừa.


/* ============================================================================
   BÀI 4: SARGABILITY & IMPLICIT CONVERSION
   Quy tắc: giữ CỘT ở vế trái "sạch" (không hàm, không phép tính, không lệch kiểu).
   Cùng tư duy này áp dụng cho partition pruning trên Spark/BigQuery/Snowflake.
============================================================================ */

-- 4A. Seek Predicate vs Residual Predicate. Cả 2 câu đều hiện "Index Seek", nhưng rà chuột vào nút Seek:
-- Câu 1 (bọc hàm): chỉ Seek được payment_type = 'CASH', phải ĐỌC HẾT các dòng CASH rồi mới lọc bằng hàm.
--                  Xem "Number of Rows Read" so với "Actual Number of Rows".
SELECT trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'CASH'
  AND YEAR(pickup_datetime) = 2009
  AND MONTH(pickup_datetime) = 1
  AND DAY(pickup_datetime) = 15;
GO

-- Câu 2 (khoảng >= / <): Seek Predicate dùng được CẢ HAI cột, Rows Read ≈ số dòng trả về
SELECT trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'CASH'
  AND pickup_datetime >= '2009-01-15'
  AND pickup_datetime <  '2009-01-16';
GO

-- 4B. IMPLICIT CONVERSION: payment_type là VARCHAR(20)
-- Bước 1: truyền NVARCHAR (N'...') -> SQL Server ép cột sang NVARCHAR, mất Seek, có tam giác vàng PlanAffectingConvert
SELECT trip_id, vendor_name, pickup_datetime, fare_amt, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = N'Dispute'
  AND pickup_datetime >= '2009-01-01'
  AND pickup_datetime <  '2009-01-16';
GO

-- Bước 2: truyền đúng kiểu VARCHAR -> Seek lại, hết cảnh báo
SELECT trip_id, vendor_name, pickup_datetime, fare_amt, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'Dispute'
  AND pickup_datetime >= '2009-01-01'
  AND pickup_datetime <  '2009-01-16';
GO
-- Lưu ý: SQL Server chỉ ép kiểu cột khi kiểu của tham số có "độ ưu tiên" cao hơn (NVARCHAR > VARCHAR).
-- Ở ETL (Python/pyodbc) tham số chuỗi thường mặc định là NVARCHAR, nên lỗi này rất hay gặp.

/*
   BẢNG VIẾT LẠI THƯỜNG GẶP (cột luôn ở một mình bên trái):
     YEAR(col) = 2009                 ->  col >= '2009-01-01' AND col < '2010-01-01'
     CONVERT(DATE, col) = '2009-01-15'->  col >= '2009-01-15' AND col < '2009-01-16'
     col + 10 > 100                   ->  col > 90
     col LIKE '%abc'                  ->  không Seek được;  col LIKE 'abc%' thì Seek được
     ISNULL(col, 0) = 0               ->  col = 0 OR col IS NULL  (cân nhắc, đo lại bằng plan)
*/


/* ============================================================================
   BÀI 5: 3 THUẬT TOÁN JOIN — NESTED LOOPS, MERGE JOIN, HASH MATCH
   Khung nhớ:
     Nested Loops : ít dòng bên ngoài + bên trong có index để Seek (OLTP, lookup).
     Merge Join   : hai bên đã SẮP XẾP sẵn theo khóa JOIN (index đúng thứ tự cột).
     Hash Match   : dữ liệu lớn, chưa có index/thứ tự; tốn RAM, có thể Spill.
============================================================================ */

-- Bảng phụ phí: CỐ TÌNH đặt PK ngược thứ tự (surcharge_seq, trip_id) — bẫy hay gặp thực tế
DROP TABLE IF EXISTS dbo.lab_trip_surcharges;
GO

CREATE TABLE dbo.lab_trip_surcharges (
    trip_id       INT NOT NULL,
    surcharge_seq INT NOT NULL,
    extra_fee     DECIMAL(10, 2) NOT NULL,
    CONSTRAINT PK_Lab_Surcharges PRIMARY KEY CLUSTERED (surcharge_seq, trip_id)
);
GO

INSERT INTO dbo.lab_trip_surcharges (trip_id, surcharge_seq, extra_fee)
SELECT trip_id, 1, tolls_amt + 0.50
FROM dbo.lab_yellow_trips;
GO

-- 5A. TRƯỚC: JOIN 3 chuyến xe. trip_id đứng thứ 2 trong PK -> không Seek được -> Hash Match + Scan cả 200k dòng
SELECT t.trip_id, t.vendor_name, t.fare_amt, s.extra_fee
FROM dbo.lab_yellow_trips t
JOIN dbo.lab_trip_surcharges s ON t.trip_id = s.trip_id
WHERE t.trip_id IN (100, 5000, 150000);
GO

-- 5B. TRƯỚC: JOIN nhiều dòng + ORDER BY trip_id -> Merge Join nhưng phải chèn nút SORT nặng cho bảng surcharges
SELECT TOP (5000) t.trip_id, t.vendor_name, t.fare_amt, s.extra_fee
FROM dbo.lab_yellow_trips t
JOIN dbo.lab_trip_surcharges s ON t.trip_id = s.trip_id
ORDER BY t.trip_id;
GO

-- Covering Index đặt trip_id ĐỨNG ĐẦU
CREATE INDEX IX_Surcharges_TripId_Cover
ON dbo.lab_trip_surcharges (trip_id, surcharge_seq)
INCLUDE (extra_fee);
GO

-- 5C. SAU (chạy lại 5A): Nested Loops + Index Seek, vài logical reads
SELECT t.trip_id, t.vendor_name, t.fare_amt, s.extra_fee
FROM dbo.lab_yellow_trips t
JOIN dbo.lab_trip_surcharges s ON t.trip_id = s.trip_id
WHERE t.trip_id IN (100, 5000, 150000);
GO

-- 5D. SAU (chạy lại 5B): Merge Join sạch, nút Sort biến mất
SELECT TOP (5000) t.trip_id, t.vendor_name, t.fare_amt, s.extra_fee
FROM dbo.lab_yellow_trips t
JOIN dbo.lab_trip_surcharges s ON t.trip_id = s.trip_id
ORDER BY t.trip_id;
GO

-- 5E. Hash Match "đúng chỗ": JOIN tổng hợp TOÀN BỘ 200k chuyến với bảng vendors nhỏ
SELECT
    v.vendor_full_name,
    COUNT(*)         AS total_trips,
    SUM(t.total_amt) AS gross_revenue,
    SUM(t.total_amt * v.commission_pct / 100.0) AS estimated_commission
FROM dbo.lab_yellow_trips t
JOIN dbo.lab_vendors v ON t.vendor_name = v.vendor_name
GROUP BY v.vendor_full_name
ORDER BY gross_revenue DESC;
GO
-- Hash không "xấu": với JOIN/aggregate lớn, đây thường là lựa chọn đúng.
-- Chỉ đáng lo khi nút Hash có tam giác vàng (Spill) -> xem Bài 11.


/* ============================================================================
   BÀI 6: SORT & AGGREGATION — KHỬ SORT, STREAM AGGREGATE vs HASH AGGREGATE
   Ý chính: thứ tự của Index giúp bỏ Sort và cho phép Stream Aggregate (nhẹ RAM).
   (Đây là đặc thù rowstore. Trên DWH/Spark tương đương là sort key / clustering.)
============================================================================ */

-- 6A. KHÔNG CẦN SORT: ORDER BY khớp thứ tự index (payment_type, pickup_datetime)
--     Plan chỉ có Top -> Index Seek (đọc Backward), 0 nút Sort
SELECT TOP (50) trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'CASH'
ORDER BY pickup_datetime DESC;
GO

-- 6B. DÍNH TOP N SORT: ORDER BY total_amt không thuộc key của index
SELECT TOP (50) trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE payment_type = 'Dispute'
ORDER BY total_amt DESC;
GO

-- 6C. (Chỉ đọc) STREAM AGGREGATE: GROUP BY theo Fare_Amt (đã sắp xếp sẵn trong IX_lab02_fare)
-- SELECT TOP (100) Fare_Amt, COUNT(*) AS trip_cnt
-- FROM dbo.yellow_tripdata
-- WHERE Fare_Amt >= 100
-- GROUP BY Fare_Amt
-- ORDER BY Fare_Amt;
-- GO

-- 6D. (Chỉ đọc) HASH AGGREGATE: GROUP BY theo vendor_name (không có index sắp xếp theo cột này)
-- SELECT vendor_name, COUNT(*) AS trip_cnt, SUM(Total_Amt) AS total_rev
-- FROM dbo.yellow_tripdata
-- GROUP BY vendor_name
-- ORDER BY total_rev DESC;
-- GO


/* ============================================================================
   BÀI 7: BENCHMARK ĐƠN GIẢN (không cần vòng lặp WHILE)
   Nguyên tắc: không kết luận từ 1 lần chạy.
============================================================================ */
/*
   Quy trình gọn:
   1. Bật SET STATISTICS IO, TIME ON.
   2. Chạy câu A lần đầu rồi BỎ QUA kết quả (lần đầu dính compile + cold cache).
   3. Chạy A thêm 2-3 lần, ghi LOGICAL READS và CPU time. Làm tương tự cho câu B.
   4. So sánh logical reads TRƯỚC, thời gian sau (thời gian dao động, reads thì ổn định).
   5. So sánh KẾT QUẢ của 2 câu: khác kết quả thì không phải "tối ưu" mà là 2 query khác nhau.
   6. Không dùng DBCC DROPCLEANBUFFERS / FREEPROCCACHE trên server dùng chung.
*/

/* ============================================================================
   BÀI 8: LUYỆN TẬP THEO 3 LOẠI QUERY CỦA DE
   Mỗi loại: viết -> xem plan -> sửa -> so logical reads TRƯỚC/SAU -> so kết quả.
============================================================================ */

-- 8B. BÀI TẬP TỰ LÀM (TRANSFORMATION): dựa trên Bài 5E, tự thêm Window Function (vd. xếp hạng doanh thu theo ngày trong từng vendor), đọc plan và tìm nút Sort/Hash nặng nhất.

-- 8C. INCREMENTAL: lấy dữ liệu thay đổi theo watermark thời gian
--     Dưới đây là cái BẪY: không có payment_type thì index hiện tại không Seek được theo pickup_datetime (vi phạm leftmost prefix)
DECLARE @last_watermark DATETIME2 = '2009-01-15';
DECLARE @new_watermark  DATETIME2 = '2009-01-16';

SELECT trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE pickup_datetime >= @last_watermark
  AND pickup_datetime <  @new_watermark;
GO
-- Bài tập: tạo index riêng cho kiểu truy vấn này rồi chạy lại, so logical reads
--   CREATE INDEX IX_Trips_Pickup ON dbo.lab_yellow_trips (pickup_datetime) INCLUDE (vendor_name, total_amt);
-- Lưu ý: dùng biến cục bộ với điều kiện khoảng khiến Optimizer đoán số dòng theo công thức cố định, không theo dữ liệu thực tế.


/* ============================================================================
   BÀI 9: STATISTICS & CARDINALITY ESTIMATION (9.45M DÒNG)
   Ý chính: Optimizer chọn Seek/Scan, thuật toán JOIN và lượng RAM dựa trên
   ƯỚC LƯỢNG SỐ DÒNG từ Statistics. Ước lượng sai -> plan sai.
   Dữ liệu thật trong IX_lab02_pax (theo ghi chú gốc):
     Passenger_Count = 0 : 455 dòng | = 4 : 201,222 dòng | = 1 : 6,362,204 dòng
   (Bỏ qua DBCC SHOW_STATISTICS: chỉ cần biết Statistics là histogram phân bố giá trị của cột.)
============================================================================ */

-- 9A. Truyền hằng số 0 (literal): Optimizer nhìn histogram -> đoán đúng ~455 dòng -> Index Seek + RID Lookup
SELECT COUNT(*) AS trip_cnt, MAX(Total_Amt) AS max_total
FROM dbo.yellow_tripdata
WHERE Passenger_Count = 0;
GO

-- 9B. Cùng giá trị 0 nhưng đặt trong BIẾN CỤC BỘ: SQL Server không "nhìn" giá trị của biến lúc biên dịch
--     -> đoán mù (~1.35 triệu dòng, lệch gần 3000 lần) -> bỏ Seek, Table Scan cả ~214,980 pages chỉ để lấy 455 dòng
--     So sánh "Estimated Number of Rows" và "Actual Number of Rows" trong plan.
DECLARE @pax BIGINT = 0;

SELECT COUNT(*) AS trip_cnt, MAX(Total_Amt) AS max_total
FROM dbo.yellow_tripdata
WHERE Passenger_Count = @pax;
GO

-- 9C. Cập nhật Statistics. Thói quen ETL: SAU KHI BULK LOAD số lượng lớn dòng, cập nhật stats của bảng đích
--     (stats cũ -> ước lượng lệch -> plan tệ cho các query phía sau).
--     (Đây là minh họa thói quen sau bulk load trên lab_yellow_trips, không ảnh hưởng 9A/9B.)
--     Tương đương: ANALYZE (PostgreSQL), ANALYZE TABLE (Spark/Hive).
UPDATE STATISTICS dbo.lab_yellow_trips WITH FULLSCAN;
GO


/* ============================================================================
   BÀI 10: PARAMETER SNIFFING (DEMO NGẮN)
   Ý chính: lần chạy ĐẦU của stored procedure quyết định plan, plan được cache
   và dùng lại cho các tham số sau. Plan tốt cho 455 dòng có thể thảm họa cho 201k dòng.
   Tương đương ở Spark: DATA SKEW (một giá trị chiếm quá nhiều dòng làm 1 task chậm cả job).
============================================================================ */

CREATE OR ALTER PROCEDURE dbo.sp_Lab_GetTripsByPax
    @Pax BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS trip_cnt, MAX(Total_Amt) AS max_total
    FROM dbo.yellow_tripdata
    WHERE Passenger_Count = @Pax;
END;
GO

-- 10A. Chạy đầu với @Pax = 0 (455 dòng) -> cache plan Index Seek + RID Lookup (~460 logical reads)
EXEC dbo.sp_Lab_GetTripsByPax @Pax = 0;
GO

-- 10B. Chạy tiếp @Pax = 4 (201,222 dòng) -> DÙNG LẠI plan cũ -> hơn 200,000 lần RID Lookup, logical reads bùng nổ
--      (KHÔNG test @Pax = 1 khi đang giữ plan Seek: 6.3 triệu lần RID Lookup sẽ chạy rất lâu)
EXEC dbo.sp_Lab_GetTripsByPax @Pax = 4;
GO

-- 10C. Cách sửa 1 dòng: OPTION (RECOMPILE) -> mỗi lần chạy biên dịch theo đúng tham số thật
CREATE OR ALTER PROCEDURE dbo.sp_Lab_GetTripsByPax
    @Pax BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS trip_cnt, MAX(Total_Amt) AS max_total
    FROM dbo.yellow_tripdata
    WHERE Passenger_Count = @Pax
    OPTION (RECOMPILE);
END;
GO

EXEC dbo.sp_Lab_GetTripsByPax @Pax = 0;  -- Index Seek + RID Lookup (~460 pages)
EXEC dbo.sp_Lab_GetTripsByPax @Pax = 4;  -- Table Scan, hợp lý (~214,980 pages tuần tự, nhanh hơn 200k lần lookup ngẫu nhiên)
GO
-- Đánh đổi: RECOMPILE tốn CPU biên dịch mỗi lần chạy. Hợp với proc chạy ít lần nhưng nặng (như ETL batch),
-- không hợp với proc chạy hàng nghìn lần/giây.


/* ============================================================================
   BÀI 11: MEMORY GRANT, SPILL TO TEMPDB, #TEMP vs @TABLE VARIABLE
   Ý chính: Sort/Hash cần RAM (Memory Grant) tính từ ƯỚC LƯỢNG số dòng. Cấp thiếu
   -> đổ dữ liệu tạm ra đĩa (SPILL) -> tam giác vàng trong plan, query chậm hẳn.
   Spark/Snowflake cũng có "spill to disk" y hệt.
============================================================================ */
/*
   Gặp Spill ngoài đời thì xử lý theo thứ tự:
   1. Ước lượng số dòng sai? -> cập nhật Statistics (Bài 9), tránh biến cục bộ.
   2. Sort/Hash có đang xử lý quá nhiều dòng/cột? -> lọc sớm, chỉ SELECT cột cần.
   3. Có thể dùng index để khử Sort? (Bài 6)
   4. Câu quá phức tạp? -> tách bước bằng #temp (staging) rồi JOIN tiếp.
*/

-- 11A. #temp vs @table variable
-- #temp: có Statistics trên cột, có thể tạo index, Optimizer đoán số dòng tốt hơn
DROP TABLE IF EXISTS #TempDisputeTrips;

SELECT trip_id, vendor_name, pickup_datetime, total_amt
INTO #TempDisputeTrips
FROM dbo.lab_yellow_trips
WHERE payment_type = 'Dispute';

SELECT v.vendor_full_name, COUNT(*) AS dispute_cnt, SUM(t.total_amt) AS dispute_amt
FROM #TempDisputeTrips t
JOIN dbo.lab_vendors v ON t.vendor_name = v.vendor_name
GROUP BY v.vendor_full_name;

DROP TABLE IF EXISTS #TempDisputeTrips;
GO

/*
   GHI NHỚ (hay hỏi phỏng vấn):
   | | #temp | @table variable |
   | Statistics trên cột | Có | Không (chỉ có số dòng, ở compat >= 150) |
   | Tạo index sau khi tạo | Được | Chỉ khai báo PK/UNIQUE/INDEX lúc DECLARE |
   | Dữ liệu lớn (hàng chục nghìn dòng trở lên) | Nên dùng | Dễ ước lượng sai |
   | Rollback | Bị rollback theo transaction | Không bị rollback |
   | Phù hợp | Staging trung gian trong ETL | Tập rất nhỏ, vài chục dòng |
   Với tập nhỏ, plan thường giống nhau; khác biệt lộ ra khi dữ liệu lớn và có JOIN phía sau.
*/


/* ============================================================================
   BÀI 12: QUERY REWRITING — CHỈ GỌI LÀ TỐI ƯU KHI KẾT QUẢ GIỐNG NHAU
   Quy tắc: viết xong phải chắc chắn 2 câu cho cùng kết quả rồi mới so hiệu năng.
============================================================================ */

-- 12A. Correlated Subquery vs JOIN + Pre-Aggregation
-- TRƯỚC
SELECT
    v.vendor_name,
    v.vendor_full_name,
    (SELECT SUM(t.total_amt) FROM dbo.lab_yellow_trips t WHERE t.vendor_name = v.vendor_name) AS total_rev
FROM dbo.lab_vendors v;
GO

-- SAU: gom nhóm 1 lượt rồi JOIN.
-- (Bản gốc bọc ISNULL(...,0): vendor không có chuyến nào sẽ ra 0 thay vì NULL -> khác kết quả bản TRƯỚC. Ở đây bỏ ISNULL cho khớp.)
WITH vendor_rev AS (
    SELECT vendor_name, SUM(total_amt) AS total_rev
    FROM dbo.lab_yellow_trips
    GROUP BY vendor_name
)
SELECT v.vendor_name, v.vendor_full_name, vr.total_rev
FROM dbo.lab_vendors v
LEFT JOIN vendor_rev vr ON v.vendor_name = vr.vendor_name;
GO

-- KIỂM TRA TƯƠNG ĐƯƠNG: kết quả phải RỖNG (không có dòng nào chỉ nằm ở một phía)
WITH a AS (
    SELECT v.vendor_name, v.vendor_full_name,
           (SELECT SUM(t.total_amt) FROM dbo.lab_yellow_trips t WHERE t.vendor_name = v.vendor_name) AS total_rev
    FROM dbo.lab_vendors v
),
b AS (
    SELECT v.vendor_name, v.vendor_full_name, vr.total_rev
    FROM dbo.lab_vendors v
    LEFT JOIN (SELECT vendor_name, SUM(total_amt) AS total_rev
               FROM dbo.lab_yellow_trips GROUP BY vendor_name) vr
           ON v.vendor_name = vr.vendor_name
)
(SELECT * FROM a EXCEPT SELECT * FROM b)
UNION ALL
(SELECT * FROM b EXCEPT SELECT * FROM a);
GO
-- Với chỉ 3 vendor, 2 plan thường GIỐNG HỆT NHAU: đừng kỳ vọng nhanh hơn. Lợi ích chính là dễ đọc,
-- và nó thật sự khác biệt khi bảng ngoài lớn hơn nhiều.

-- 12B. UNION vs UNION ALL
-- UNION = nối + loại trùng (thêm bước Distinct/Sort). UNION ALL = nối thẳng.
-- CHỈ đổi được khi 2 nhánh KHÔNG THỂ có dòng trùng nhau.

-- 12B-1. VÍ DỤ ĐỔI NGHIỆP VỤ (2 nhánh có thể giao nhau): so 2 con số, nếu khác nhau là 2 query KHÔNG tương đương
SELECT COUNT(*) AS cnt_union FROM (
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type = 'Dispute'
    UNION
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE total_amt >= 100
) x;

SELECT COUNT(*) AS cnt_union_all FROM (
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type = 'Dispute'
    UNION ALL
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE total_amt >= 100
) x;
GO
-- cnt_union_all - cnt_union = số chuyến vừa 'Dispute' vừa total_amt >= 100. Nếu = 0 chỉ là do dữ liệu hiện tại,
-- không phải do query an toàn.

-- 12B-2. VIẾT LẠI CHO 2 NHÁNH LOẠI TRỪ NHAU (nhánh 2 thêm payment_type <> 'Dispute') -> UNION ALL an toàn
SELECT COUNT(*) AS cnt_union FROM (
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type = 'Dispute'
    UNION
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type <> 'Dispute' AND total_amt >= 100
) x;

SELECT COUNT(*) AS cnt_union_all FROM (
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type = 'Dispute'
    UNION ALL
    SELECT trip_id, vendor_name, total_amt FROM dbo.lab_yellow_trips WHERE payment_type <> 'Dispute' AND total_amt >= 100
) x;
GO
-- Lần này 2 số luôn bằng nhau (payment_type của bảng lab không NULL). Xem plan: UNION có thêm bước loại trùng, UNION ALL thì không.

-- 12C. Bẫy NOT IN khi tập con có NULL vs NOT EXISTS (cùng 1 nguồn dữ liệu)
DROP TABLE IF EXISTS #blocked_vendors;
CREATE TABLE #blocked_vendors (vendor_name VARCHAR(10) NULL);
INSERT INTO #blocked_vendors VALUES ('CMT'), (NULL);   -- 1 giá trị NULL lẫn trong danh sách
GO

-- TRƯỚC (lỗi logic âm thầm): NOT IN gặp NULL -> mọi so sánh thành UNKNOWN -> trả về 0 dòng
SELECT COUNT(*) AS cnt_not_in
FROM dbo.lab_yellow_trips t
WHERE t.vendor_name NOT IN (SELECT vendor_name FROM #blocked_vendors);

-- SAU: NOT EXISTS không bị NULL đánh lừa -> ra đúng số chuyến không thuộc 'CMT'
SELECT COUNT(*) AS cnt_not_exists
FROM dbo.lab_yellow_trips t
WHERE NOT EXISTS (SELECT 1 FROM #blocked_vendors b WHERE b.vendor_name = t.vendor_name);
GO

-- Đối chiếu: cùng ý nghĩa "không thuộc CMT" viết thẳng
SELECT COUNT(*) AS cnt_expected FROM dbo.lab_yellow_trips WHERE vendor_name <> 'CMT';
GO
-- Nếu cột có thể NULL, vendor_name NULL sẽ không vào kết quả của <> ; hãy luôn nghĩ tới NULL khi viết điều kiện loại trừ.
DROP TABLE IF EXISTS #blocked_vendors;
GO

-- 12D. Predicate Pushdown qua Window Function
-- Quy tắc: WHERE bên ngoài chỉ được "đẩy xuống" trước bước xếp hạng khi nó lọc trên cột PARTITION BY.
-- Lọc cột khác (như trip_id) sẽ làm ĐỔI thứ hạng nên Optimizer không được phép đẩy.

-- 12D-1. Lọc theo cột PARTITION BY (vendor_name): đẩy xuống được
--        Xem plan: điều kiện vendor_name nằm ngay ở nút đọc bảng, nút Sort chỉ xử lý dòng của 'CMT'
WITH TripRank AS (
    SELECT trip_id, vendor_name, total_amt,
           ROW_NUMBER() OVER (PARTITION BY vendor_name ORDER BY total_amt DESC) AS rn
    FROM dbo.lab_yellow_trips
)
SELECT trip_id, vendor_name, total_amt, rn
FROM TripRank
WHERE vendor_name = 'CMT' AND rn <= 5;
GO

-- 12D-2. (Chỉ đọc) Lọc theo trip_id (KHÔNG phải cột partition): phải xếp hạng toàn bảng -> Scan + Sort 200k dòng. Đây là đúng đắn, không phải lỗi.
-- WITH TripRank AS (
--     SELECT trip_id, vendor_name, total_amt,
--            ROW_NUMBER() OVER (ORDER BY total_amt DESC) AS rn
--     FROM dbo.lab_yellow_trips
-- )
-- SELECT trip_id, vendor_name, total_amt, rn
-- FROM TripRank
-- WHERE trip_id = 12345;
-- GO
-- Lưu ý: đổi thành PARTITION BY trip_id -> mỗi trip_id là 1 nhóm riêng -> rn luôn = 1.
-- Nhanh thật, nhưng không còn là thứ hạng toàn bảng nữa (đổi nghiệp vụ, KHÔNG phải tối ưu).

-- 12E. Phân trang sâu: OFFSET/FETCH vs Keyset Pagination
-- TRƯỚC: phải đọc rồi bỏ qua 180,000 dòng mới lấy 20 dòng, càng sang trang sâu càng chậm
SELECT trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
ORDER BY trip_id
OFFSET 180000 ROWS FETCH NEXT 20 ROWS ONLY;
GO

-- SAU: nhớ trip_id cuối của trang trước, Seek thẳng tới đó -> logical reads gần như cố định ở mọi trang
DECLARE @last_trip_id INT = 180000;

SELECT TOP (20) trip_id, vendor_name, pickup_datetime, total_amt
FROM dbo.lab_yellow_trips
WHERE trip_id > @last_trip_id
ORDER BY trip_id;
GO
/*
   Keyset chỉ đúng khi cột sắp xếp là DUY NHẤT (hoặc thêm cột phụ để duy nhất) và ứng dụng giữ "khóa cuối trang".
   Đây cũng là nền tảng của job kéo dữ liệu theo batch / watermark trong ETL.
*/
-- Hai cách chỉ cho kết quả giống nhau khi trip_id liên tục (IDENTITY, không có lỗ hổng): OFFSET lấy theo vị trí, keyset lấy theo giá trị.


/* ============================================================================
   DỌN DẸP (tùy chọn)
============================================================================ */
-- DROP PROCEDURE IF EXISTS dbo.sp_Lab_GetTripsByPax;
-- DROP TABLE IF EXISTS dbo.lab_trip_surcharges;
-- DROP INDEX IF EXISTS IX_Trips_Pickup ON dbo.lab_yellow_trips;

SET STATISTICS IO, TIME OFF;
GO
