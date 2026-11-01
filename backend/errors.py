"""
Vietnamese 422 responses for request validation (FastAPI's default is English pydantic text that also
echoes the rejected input). Body: {"detail": "<one Vietnamese sentence>", "errors": [{loc, msg, type}]};
`input` and `ctx` are never returned.
"""
from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

MSG_INVALID = "Dữ liệu yêu cầu không hợp lệ"

# pydantic v2 error type -> Vietnamese template (formatted with the error's ctx: limits, never the input).
_MESSAGES = {
    "missing": "thiếu giá trị bắt buộc",
    "greater_than": "phải lớn hơn {gt}",
    "greater_than_equal": "phải lớn hơn hoặc bằng {ge}",
    "less_than": "phải nhỏ hơn {lt}",
    "less_than_equal": "phải nhỏ hơn hoặc bằng {le}",
    "int_parsing": "phải là số nguyên",
    "int_type": "phải là số nguyên",
    "int_from_float": "phải là số nguyên",
    "float_parsing": "phải là số",
    "float_type": "phải là số",
    "finite_number": "phải là số hữu hạn",
    "bool_parsing": "phải là true hoặc false",
    "bool_type": "phải là true hoặc false",
    "string_type": "phải là chuỗi ký tự",
    "string_too_short": "quá ngắn (tối thiểu {min_length} ký tự)",
    "string_too_long": "quá dài (tối đa {max_length} ký tự)",
    "string_pattern_mismatch": "sai định dạng",
    "too_short": "cần ít nhất {min_length} phần tử",
    "too_long": "tối đa {max_length} phần tử",
    "list_type": "phải là danh sách",
    "dict_type": "phải là đối tượng JSON",
    "model_type": "phải là đối tượng JSON",
    "model_attributes_type": "phải là đối tượng JSON",
    "literal_error": "phải là một trong: {expected}",
    "enum": "phải là một trong: {expected}",
    "extra_forbidden": "trường không được hỗ trợ",
    "json_invalid": "JSON không hợp lệ",
    "json_type": "JSON không hợp lệ",
    "datetime_parsing": "thời điểm không hợp lệ",
    "date_parsing": "ngày không hợp lệ",
}
_FALLBACK = "giá trị không hợp lệ"
_SOURCES = {"body", "query", "path", "header", "cookie"}


def vietnamese_message(error: dict) -> str:
    kind = error.get("type", "")
    if kind == "value_error":
        # Our own validators raise ValueError with an authored Vietnamese message.
        msg = str(error.get("msg", ""))
        return msg.removeprefix("Value error, ") or _FALLBACK
    template = _MESSAGES.get(kind)
    if template is None:
        return _FALLBACK
    try:
        return template.format(**{k: v for k, v in (error.get("ctx") or {}).items() if isinstance(v, (int, float, str))})
    except (KeyError, IndexError, ValueError):
        return _FALLBACK


def _field(loc) -> str:
    parts = [str(p)[:64] for p in loc or () if not (isinstance(p, str) and p in _SOURCES)]
    return ".".join(parts)


def validation_payload(errors) -> dict:
    items, sentences = [], []
    for e in errors:
        msg = vietnamese_message(e)
        field = _field(e.get("loc"))
        loc = [p if isinstance(p, int) else str(p)[:64] for p in e.get("loc") or ()]
        items.append({"loc": loc, "msg": msg, "type": e.get("type", "")})
        sentences.append(f"{field}: {msg.rstrip('.')}" if field else msg.rstrip('.'))
    detail = MSG_INVALID + (": " + "; ".join(dict.fromkeys(sentences)) if sentences else "") + "."
    return {"detail": detail, "errors": items}


async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(status_code=422, content=validation_payload(exc.errors()))
