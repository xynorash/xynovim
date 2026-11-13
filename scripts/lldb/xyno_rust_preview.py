"""Content previews for Rust containers in LLDB summaries (loaded after rust's lldb_lookup.py).

rust's own summaries stop at the shape: Vec -> `size=3`, HashMap -> `size=1`, Rc -> `strong=2, weak=0`,
RefCell -> `borrow=0`. A debugger value column is read in one glance, so these add the content:

    Vec<i32>      size=3 [1, 2, 3]            HashMap   size=1 {"a": 1}
    Rc<String>    strong=2, weak=0 "rc"       RefCell   borrow=0 5

Every function falls back to the stock summary on any error, so a layout change in a newer toolchain
degrades to what rust ships instead of breaking the variables view. Previews are capped (items and
characters) because they are computed for every visible value on every stop.
"""
import lldb

MAX_ITEMS = 8
MAX_CHARS = 100


def _stock(name):
    try:
        import lldb_providers

        return getattr(lldb_providers, name)
    except Exception:
        return None


def _one(v, depth=0):
    """One-line rendering of a child value: its summary, else its value, else `{..}`."""
    if v is None or not v.IsValid():
        return "?"
    s = v.GetSummary()
    if s is None:
        s = v.GetValue()
    if s is None:
        n = v.GetNumChildren()
        if n == 0:
            return "{}"
        if depth >= 1 or n > 4:
            return "{..}"
        parts = []
        for i in range(n):
            c = v.GetChildAtIndex(i)
            parts.append("%s: %s" % (c.GetName(), _one(c, depth + 1)))
        return "{" + ", ".join(parts) + "}"
    return s


def _clip(text):
    return text if len(text) <= MAX_CHARS else text[: MAX_CHARS - 1] + "…"


def _items(valobj, fmt):
    n = valobj.GetNumChildren()
    out = []
    for i in range(min(n, MAX_ITEMS)):
        out.append(fmt(valobj.GetChildAtIndex(i)))
    more = ", …" if n > MAX_ITEMS else ""
    return n, ", ".join(out) + more


def seq_summary(valobj, _dict):
    """Vec, VecDeque, slices, arrays of Vec-like synthetic providers."""
    try:
        n, body = _items(valobj, _one)
        return _clip("size=%d [%s]" % (n, body))
    except Exception:
        stock = _stock("SizeSummaryProvider")
        return stock(valobj, _dict) if stock else ""


def _pair(child):
    """A HashMap entry: the provider yields `[i]` children that are (key, value) tuples."""
    if child.GetNumChildren() >= 2:
        return "%s: %s" % (_one(child.GetChildAtIndex(0)), _one(child.GetChildAtIndex(1)))
    return _one(child)


def map_summary(valobj, _dict):
    try:
        n, body = _items(valobj, _pair)
        return _clip("size=%d {%s}" % (n, body))
    except Exception:
        stock = _stock("SizeSummaryProvider")
        return stock(valobj, _dict) if stock else ""


def set_summary(valobj, _dict):
    try:
        n, body = _items(valobj, _one)
        return _clip("size=%d {%s}" % (n, body))
    except Exception:
        stock = _stock("SizeSummaryProvider")
        return stock(valobj, _dict) if stock else ""


def rc_summary(valobj, _dict):
    stock = _stock("StdRcSummaryProvider")
    base = stock(valobj, _dict) if stock else ""
    try:
        val = valobj.GetChildMemberWithName("value")
        if val.IsValid():
            return _clip("%s %s" % (base, _one(val)))
    except Exception:
        pass
    return base


def refcell_summary(valobj, _dict):
    stock = _stock("StdRefSummaryProvider")
    base = stock(valobj, _dict) if stock else ""
    try:
        # the wrapped value: RefCell holds it in an UnsafeCell, Ref/RefMut behind a pointer
        raw = valobj.GetNonSyntheticValue()
        val = raw.GetChildMemberWithName("value")
        for _ in range(2):
            name = val.GetTypeName() or ""
            if "UnsafeCell<" in name or "Cell<" in name:
                val = val.GetChildMemberWithName("value")
            elif val.TypeIsPointerType():
                val = val.Dereference()
        if val.IsValid():
            return _clip("%s %s" % (base, _one(val)))
    except Exception:
        pass
    return base


def __lldb_init_module(debugger, _dict):
    # Own category, enabled after "Rust": lldb consults the most recently enabled category first.
    cat = debugger.GetCategory("XynoRust")
    if not cat.IsValid():
        cat = debugger.CreateCategory("XynoRust")
    opts = lldb.eTypeOptionCascade
    # The patterns of rust's own registrations in lldb_lookup.py.
    table = [
        (r"^(alloc::([a-z_]+::)+)Vec<.+>$", "seq_summary"),
        (r"^(alloc::([a-z_]+::)+)VecDeque<.+>$", "seq_summary"),
        (r"^&(mut )?\[.+\]$", "seq_summary"),
        (r"^(std::collections::([a-z_]+::)+)HashMap<.+>$", "map_summary"),
        (r"^(std::collections::([a-z_]+::)+)HashSet<.+>$", "set_summary"),
        (r"^(alloc::([a-z_]+::)+)Rc<.+>$", "rc_summary"),
        (r"^(alloc::([a-z_]+::)+)Arc<.+>$", "rc_summary"),
        (r"^(core::([a-z_]+::)+)Ref(Cell|Mut)?<.+>$", "refcell_summary"),
    ]
    for rx, fn in table:
        spec = lldb.SBTypeNameSpecifier(rx, lldb.eFormatterMatchRegex)
        summ = lldb.SBTypeSummary.CreateWithFunctionName(__name__ + "." + fn, opts)
        cat.AddTypeSummary(spec, summ)
    # enabling moves a category to the front; it must be re-enabled for that if it is on already
    cat.SetEnabled(False)
    cat.SetEnabled(True)
