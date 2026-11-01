"""Build the progress PDF from a versioned Vietnamese checklist."""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
from html import escape
import json
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, KeepTogether, PageBreak

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/progress_20261026.json"
OUTPUT = ROOT.parent / "deliverables/Sky_Weather_Tien_Do_Hoan_Thien.pdf"
STATUS = {"pending": "Chưa làm", "working": "Đang làm", "review": "Chờ kiểm chứng",
          "done": "Đã hoàn tất", "external": "Cần điều kiện bên ngoài"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--set", action="append", default=[], metavar="ID=STATUS")
    parser.add_argument("--evidence", action="append", default=[], metavar="ID=TEXT")
    parser.add_argument("--note", action="append", default=[])
    parser.add_argument("--check", action="append", default=[])
    args = parser.parse_args()
    data = json.loads(SOURCE.read_text(encoding="utf-8"))
    tasks = {task["id"]: task for task in data["tasks"]}
    for update in args.set:
        key, value = update.split("=", 1)
        if value not in STATUS or key not in tasks:
            parser.error("Invalid task/status: " + update)
        tasks[key]["status"] = value
    for update in args.evidence:
        key, value = update.split("=", 1)
        tasks[key]["evidence"] = value
    stamp = datetime.now(timezone(timedelta(hours=7))).strftime("%d/%m/%Y %H:%M (+07)")
    if args.note or args.set or args.evidence or args.check:
        data["updated"] = stamp
        data["history"].extend({"at": stamp, "text": note} for note in args.note)
        data["checks"].extend({"at": stamp, "text": check} for check in args.check)
        SOURCE.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pdfmetrics.registerFont(TTFont("Progress", "C:/Windows/Fonts/arial.ttf"))
    pdfmetrics.registerFont(TTFont("ProgressBold", "C:/Windows/Fonts/arialbd.ttf"))
    pdfmetrics.registerFontFamily("Progress", normal="Progress", bold="ProgressBold")
    styles = {}
    for name, size, leading in [("title", 25, 31), ("heading", 13, 19), ("body", 10, 15), ("small", 9, 13), ("cell", 9, 13)]:
        styles[name] = ParagraphStyle(name, fontName="ProgressBold" if name in ("title", "heading") else "Progress",
                                      fontSize=size, leading=leading, textColor=colors.HexColor("#172B35"),
                                      spaceAfter=7, spaceBefore=9 if name == "heading" else 0)
    styles["cell"].spaceAfter = 0
    styles["cell"].leading = 12
    styles["task"] = ParagraphStyle("task", parent=styles["heading"], fontSize=11, leading=15, spaceBefore=6, spaceAfter=4)
    styles["taskbody"] = ParagraphStyle("taskbody", parent=styles["body"], fontSize=9.5, leading=13, spaceAfter=3)
    styles["tasksmall"] = ParagraphStyle("tasksmall", parent=styles["small"], leading=12, spaceAfter=3)

    def p(text, style="body"):
        return Paragraph(escape(text).replace("\n", "<br/>"), styles[style])

    counts = Counter(task["status"] for task in data["tasks"])
    story = [p("SKY WEATHER", "small"), p("Theo dõi hoàn thiện dự án", "title"),
             p("Kế hoạch thực hiện, trạng thái nghiệm thu và kết quả kiểm chứng."),
             p("Cập nhật: " + data["updated"], "small"),
             p(" | ".join(f"{STATUS[key]}: {counts[key]}" for key in STATUS), "small"),
             Spacer(1, 10), p("Phạm vi và nguyên tắc", "heading")]
    story.extend(p(text) for text in data["scope"])
    story.append(p("Danh sách công việc", "heading"))
    rows = [[p("Mã / ưu tiên", "cell"), p("Công việc", "cell"), p("Trạng thái", "cell")]]
    for task in data["tasks"]:
        rows.append([p(task["id"] + " / " + task["priority"], "cell"), p(task["title"], "cell"), p(STATUS[task["status"]], "cell")])
    table = Table(rows, colWidths=[69, 294, 132], repeatRows=1, hAlign="LEFT")
    table.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EAF1F4")),
                               ("VALIGN", (0, 0), (-1, -1), "TOP"),
                               ("LEFTPADDING", (0, 0), (-1, -1), 9), ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                               ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
                               ("LINEBELOW", (0, 0), (-1, -1), .4, colors.HexColor("#DCE3E7"))]))
    story.extend([table, PageBreak(), p("Chi tiết và tiêu chí nghiệm thu", "heading")])
    for task in data["tasks"]:
        story.append(KeepTogether([p(task["id"] + " - " + task["title"], "task"),
                                   p(task["priority"] + " | " + STATUS[task["status"]], "tasksmall"),
                                   p("Mục tiêu: " + task["acceptance"], "taskbody"),
                                   p("Bằng chứng / điều kiện: " + task["evidence"], "tasksmall")]))
    story.extend([PageBreak(), p("Kiểm thử và giới hạn", "heading")])
    for check in data["checks"]:
        story.append(p(check["at"] + " - " + check["text"]))
    story.append(p("Nhật ký cập nhật", "heading"))
    for event in data["history"]:
        story.append(p(event["at"] + " - " + event["text"]))
    story.append(p("Cách cập nhật", "heading"))
    story.append(p("PDF được tạo lại sau mỗi nhóm việc. Đã hoàn tất chỉ khi có kiểm thử phù hợp; test giả lập không thay thế SMTP, điện thoại, Docker hay production. Không tự cập nhật khi phiên làm việc đã kết thúc."))

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Progress", 8)
        canvas.setFillColor(colors.HexColor("#53616C"))
        canvas.drawString(50, 29, "Sky Weather | Tiến độ 26/10/2026 | Asia/Bangkok (+07)")
        canvas.drawRightString(A4[0] - 50, 29, f"Trang {doc.page}")
        canvas.restoreState()

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    temp = OUTPUT.with_suffix(".tmp.pdf")
    doc = SimpleDocTemplate(str(temp), pagesize=A4, leftMargin=50, rightMargin=50, topMargin=45, bottomMargin=58,
                            title="Sky Weather - Tiến độ hoàn thiện", author="Sky Weather")
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    temp.replace(OUTPUT)
    print(OUTPUT)


if __name__ == "__main__":
    main()
