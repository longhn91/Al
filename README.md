# AI-assisted XAUUSD Scalper EA (MT5)

Expert Advisor giao dịch vàng (XAUUSD) khung M1 với phong cách scalping toàn thời gian, tận dụng mô hình OpenAI để theo dõi hiệu quả, kiểm soát rủi ro và chủ động tối ưu Stop Loss/Take Profit lẫn hệ số rủi ro.

## 1. Chuẩn bị môi trường MetaTrader 5

1. Mở **MetaTrader 5** → `File` → `Open Data Folder`.
2. Điều hướng tới `MQL5/Experts` và sao chép file `XAUUSD_AI_Scalper.mq5` vào thư mục này. *Khuyến nghị:* trên GitHub hãy chọn nút **Raw** rồi `Ctrl+S` để lưu file, hoặc dùng `Download ZIP` để tránh lỗi mã hóa khi copy/paste.
3. Mở **MetaEditor**, nạp file EA và bấm **Compile**. Khi biên dịch thành công sẽ tạo file `XAUUSD_AI_Scalper.ex5`.

## 2. Cho phép EA gọi OpenAI

1. Trong MetaTrader 5 mở `Tools` → `Options` → tab `Expert Advisors`.
2. Tick **Allow WebRequest for listed URL**.
3. Thêm URL `https://api.openai.com` vào danh sách và nhấn **OK**.
4. Đảm bảo tài khoản OpenAI của bạn có quyền gọi **Chat Completions API** và lấy API key hợp lệ.

## 3. Gắn EA lên chart XAUUSD M1

1. Trên MT5 mở chart **XAUUSD** khung thời gian **M1**.
2. Kéo thả EA `XAUUSD_AI_Scalper` lên chart hoặc bấm đúp trong Navigator.
3. Trong cửa sổ Inputs:
   - `InpOpenAIKey`: dán API key OpenAI (định dạng `sk-...`).
   - `InpModel`: mặc định `gpt-4.1-mini`, có thể đổi sang model khác hỗ trợ Chat Completions API.
   - `InpAIRefreshMinutes`: tần suất EA yêu cầu gợi ý mới từ AI.
   - Các thông số EMA, giới hạn spread, rủi ro cơ bản… điều chỉnh theo chiến lược cá nhân.
4. Bật nút **Algo Trading** để EA hoạt động.

## 4. Cơ chế hoạt động

- EA ghi nhận hiệu suất giao dịch trong ngày (Win rate, Profit factor, chuỗi thua…) và lưu vào `Performance_Data.json`.
- Theo chu kỳ `InpAIRefreshMinutes`, EA gửi dữ liệu hiệu suất + thiết lập hiện tại cho OpenAI Chat Completions API.
- AI trả về JSON gồm: `trading_enabled`, `stop_loss_pips`, `take_profit_pips`, `risk_multiplier`, `reasoning`.
- EA tự động xác thực biên độ SL/TP (SL: 3–10 pips, TP ≥ SL × 1.2, Risk: 0.5–1.5) rồi áp dụng cho vị thế mới/cũ.
- Lệnh vào dựa trên giao cắt EMA nhanh/chậm ở M1; EA giới hạn số lệnh mở bằng magic number riêng.
- Bộ lọc vận hành nâng cao:
  - **Session filter**: chỉ vào lệnh trong khung giờ `InpSessionStartHour` → `InpSessionEndHour` (theo giờ server).
  - **ATR filter**: yêu cầu ATR(`InpAtrPeriod`) tối thiểu `InpAtrMinPips` để tránh giai đoạn thị trường đứng yên.
  - **Daily drawdown guard**: khi equity giảm vượt `InpMaxDailyDrawdownPercent`, EA tạm khoá lệnh mới tới hết ngày.
  - **Break-even lock**: khi lợi nhuận đạt `InpBreakEvenTriggerPips`, SL dịch về hòa vốn + `InpBreakEvenLockPips` để giữ lãi.

## 5. File cấu hình và nhật ký

| File | Mục đích |
| ---- | -------- |
| `AI_Recommendations.json` | Lưu khuyến nghị AI gần nhất, được tải lại khi khởi động EA. |
| `Performance_Data.json` | Ghi hiệu suất giao dịch nội ngày để AI tham chiếu. |

Log trong **Experts** sẽ hiển thị checklist cài đặt, tình trạng gọi API, lỗi WebRequest (ví dụ cần cấp quyền URL).

> ⚠️ *Lưu ý:* MetaTrader 5 không thể cài đặt trực tiếp trong môi trường GitHub Codespaces/Actions hay container của repo này. Hãy biên dịch & kiểm thử EA trên máy Windows cài MT5 hoặc VPS chuyên dụng.

## 6. Khắc phục sự cố phổ biến

- **Lỗi 4014**: chưa thêm `https://api.openai.com` vào WebRequest.
- **HTTP status khác 200**: kiểm tra API key, hạn mức tài khoản hoặc model.
- **Không có lệnh**: xác nhận spread thấp hơn `InpMaxSpreadPoints`, đảm bảo AI chưa tắt `trading_enabled`.
- **Không có dữ liệu AI**: EA dùng cấu hình mặc định (SL 6 pips, TP 10 pips, Risk 1.0) cho tới khi gọi API thành công.

## 7. Tùy biến & mở rộng

- Điều chỉnh bộ lọc xu hướng, tín hiệu vào lệnh, hoặc thêm xác nhận đa khung tuỳ ý.
- Kết hợp thêm quản lý lệnh thủ công, trailing stop… nhưng giữ nguyên logic ghi nhận hiệu suất để AI có dữ liệu.
- Có thể gom báo cáo `AI_Recommendations.json` và `Performance_Data.json` để phân tích thêm ngoài MT5.

> Lưu ý: luôn kiểm thử trên tài khoản demo trước khi đưa vào giao dịch thật. AI cung cấp khuyến nghị dựa trên dữ liệu quá khứ nội ngày, trader vẫn cần giám sát thị trường liên tục.
