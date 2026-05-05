#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>

#include "tool_config.h"

/* IEnumExplorerCommand {a88826f8-186f-4987-aade-ea0cef8fbfe8} */
static const IID IID_IEnumExplorerCommand = {
    0xa88826f8, 0x186f, 0x4987,
    {0xaa, 0xde, 0xea, 0x0c, 0xef, 0x8f, 0xbf, 0xe8}
};

static const wchar_t TOOL_EXE[] = TOOL_EXE_PATH;
static const wchar_t TOOL_ICON[] = TOOL_ICON_PATH;
static LONG g_dllRef = 0;

/* ── Helpers ─────────────────────────────────────────────────────────── */

static wchar_t *GetFolderFromShellItems(IShellItemArray *psia) {
    static wchar_t buf[MAX_PATH];
    buf[0] = 0;
    if (!psia) return buf;
    IShellItem *psi = NULL;
    if (SUCCEEDED(psia->lpVtbl->GetItemAt(psia, 0, &psi))) {
        LPWSTR path = NULL;
        if (SUCCEEDED(psi->lpVtbl->GetDisplayName(psi, SIGDN_FILESYSPATH, &path))) {
            lstrcpynW(buf, path, MAX_PATH);
            CoTaskMemFree(path);
        }
        psi->lpVtbl->Release(psi);
    }
    return buf;
}

static void LaunchTool(IShellItemArray *psia, const wchar_t *extraArgs) {
    wchar_t *folder = GetFolderFromShellItems(psia);
    wchar_t cmdLine[1024];

    if (extraArgs && extraArgs[0])
        wsprintfW(cmdLine, L"cmd.exe /k \"\"%s\" %s\"", TOOL_EXE, extraArgs);
    else
        wsprintfW(cmdLine, L"cmd.exe /k \"\"%s\"\"", TOOL_EXE);

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {0};
    CreateProcessW(NULL, cmdLine, NULL, NULL, FALSE, CREATE_NEW_CONSOLE,
                   NULL, folder[0] ? folder : NULL, &si, &pi);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    if (pi.hThread)  CloseHandle(pi.hThread);
}

/* ═══════════════════════════════════════════════════════════════════════
   Sub-command: a lightweight IExplorerCommand for each menu item
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IExplorerCommandVtbl *lpVtbl;
    LONG                  refCount;
    const wchar_t        *title;
    const wchar_t        *tooltip;
    const wchar_t        *args;  /* NULL = no extra args */
} SubCommand;

static HRESULT STDMETHODCALLTYPE Sub_QI(IExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Sub_AddRef(IExplorerCommand *This) {
    return InterlockedIncrement(&((SubCommand *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Sub_Release(IExplorerCommand *This) {
    SubCommand *sc = (SubCommand *)This;
    LONG r = InterlockedDecrement(&sc->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, sc); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Sub_GetTitle(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)p; return SHStrDupW(((SubCommand *)This)->title, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetIcon(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p;
    wchar_t buf[MAX_PATH + 8];
    wsprintfW(buf, L"%s,0", TOOL_ICON);
    return SHStrDupW(buf, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetToolTip(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)p; return SHStrDupW(((SubCommand *)This)->tooltip, out);
}

static HRESULT STDMETHODCALLTYPE Sub_GetCanonicalName(IExplorerCommand *This, GUID *g) {
    (void)This; *g = CLSID_Tool; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_GetState(IExplorerCommand *This, IShellItemArray *p, BOOL b, EXPCMDSTATE *s) {
    (void)This; (void)p; (void)b; *s = ECS_ENABLED; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_Invoke(IExplorerCommand *This, IShellItemArray *psia, IBindCtx *pbc) {
    (void)pbc;
    LaunchTool(psia, ((SubCommand *)This)->args);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_GetFlags(IExplorerCommand *This, EXPCMDFLAGS *f) {
    (void)This; *f = ECF_DEFAULT; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Sub_EnumSub(IExplorerCommand *This, IEnumExplorerCommand **pp) {
    (void)This; *pp = NULL; return E_NOTIMPL;
}

static IExplorerCommandVtbl g_SubVtbl = {
    Sub_QI, Sub_AddRef, Sub_Release,
    Sub_GetTitle, Sub_GetIcon, Sub_GetToolTip,
    Sub_GetCanonicalName, Sub_GetState, Sub_Invoke,
    Sub_GetFlags, Sub_EnumSub
};

static SubCommand *CreateSubCommand(const wchar_t *title, const wchar_t *tooltip, const wchar_t *args) {
    SubCommand *sc = (SubCommand *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(SubCommand));
    if (!sc) return NULL;
    sc->lpVtbl   = &g_SubVtbl;
    sc->refCount = 1;
    sc->title    = title;
    sc->tooltip  = tooltip;
    sc->args     = args;
    InterlockedIncrement(&g_dllRef);
    return sc;
}

/* ═══════════════════════════════════════════════════════════════════════
   IEnumExplorerCommand — enumerates the sub-commands from g_menuItems
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IEnumExplorerCommandVtbl *lpVtbl;
    LONG   refCount;
    ULONG  index;
} SubCmdEnum;

static HRESULT STDMETHODCALLTYPE Enum_QI(IEnumExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IEnumExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Enum_AddRef(IEnumExplorerCommand *This) {
    return InterlockedIncrement(&((SubCmdEnum *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Enum_Release(IEnumExplorerCommand *This) {
    SubCmdEnum *e = (SubCmdEnum *)This;
    LONG r = InterlockedDecrement(&e->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, e); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Enum_Next(IEnumExplorerCommand *This,
    ULONG celt, IExplorerCommand **pUICommand, ULONG *pceltFetched)
{
    SubCmdEnum *e = (SubCmdEnum *)This;
    ULONG fetched = 0;

    while (fetched < celt && e->index < NUM_MENU_ITEMS) {
        const MenuItemDef *def = &g_menuItems[e->index];
        SubCommand *sc = CreateSubCommand(def->title, def->tooltip, def->args);
        if (!sc) break;
        pUICommand[fetched++] = (IExplorerCommand *)sc;
        e->index++;
    }
    if (pceltFetched) *pceltFetched = fetched;
    return (fetched == celt) ? S_OK : S_FALSE;
}

static HRESULT STDMETHODCALLTYPE Enum_Skip(IEnumExplorerCommand *This, ULONG celt) {
    SubCmdEnum *e = (SubCmdEnum *)This;
    e->index += celt;
    return (e->index <= NUM_MENU_ITEMS) ? S_OK : S_FALSE;
}

static HRESULT STDMETHODCALLTYPE Enum_Reset(IEnumExplorerCommand *This) {
    ((SubCmdEnum *)This)->index = 0; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Enum_Clone(IEnumExplorerCommand *This, IEnumExplorerCommand **pp) {
    (void)This; *pp = NULL; return E_NOTIMPL;
}

static IEnumExplorerCommandVtbl g_EnumVtbl = {
    Enum_QI, Enum_AddRef, Enum_Release,
    Enum_Next, Enum_Skip, Enum_Reset, Enum_Clone
};

static SubCmdEnum *CreateEnum(void) {
    SubCmdEnum *e = (SubCmdEnum *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(SubCmdEnum));
    if (!e) return NULL;
    e->lpVtbl   = &g_EnumVtbl;
    e->refCount = 1;
    e->index    = 0;
    InterlockedIncrement(&g_dllRef);
    return e;
}

/* ═══════════════════════════════════════════════════════════════════════
   Parent IExplorerCommand — the tool-specific dropdown
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct {
    IExplorerCommandVtbl *lpVtbl;
    LONG refCount;
} ParentCmd;

static HRESULT STDMETHODCALLTYPE Par_QI(IExplorerCommand *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IExplorerCommand)) {
        *ppv = This; This->lpVtbl->AddRef(This); return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE Par_AddRef(IExplorerCommand *This) {
    return InterlockedIncrement(&((ParentCmd *)This)->refCount);
}

static ULONG STDMETHODCALLTYPE Par_Release(IExplorerCommand *This) {
    ParentCmd *p = (ParentCmd *)This;
    LONG r = InterlockedDecrement(&p->refCount);
    if (r == 0) { HeapFree(GetProcessHeap(), 0, p); InterlockedDecrement(&g_dllRef); }
    return r;
}

static HRESULT STDMETHODCALLTYPE Par_GetTitle(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TITLE, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetIcon(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p;
    wchar_t buf[MAX_PATH + 8];
    wsprintfW(buf, L"%s,0", TOOL_ICON);
    return SHStrDupW(buf, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetToolTip(IExplorerCommand *This, IShellItemArray *p, LPWSTR *out) {
    (void)This; (void)p; return SHStrDupW(TOOL_PARENT_TOOLTIP, out);
}

static HRESULT STDMETHODCALLTYPE Par_GetCanonicalName(IExplorerCommand *This, GUID *g) {
    (void)This; *g = CLSID_Tool; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_GetState(IExplorerCommand *This, IShellItemArray *p, BOOL b, EXPCMDSTATE *s) {
    (void)This; (void)p; (void)b; *s = ECS_ENABLED; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_Invoke(IExplorerCommand *This, IShellItemArray *p, IBindCtx *b) {
    (void)This; (void)p; (void)b; return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE Par_GetFlags(IExplorerCommand *This, EXPCMDFLAGS *f) {
    (void)This; *f = ECF_HASSUBCOMMANDS; return S_OK;
}

static HRESULT STDMETHODCALLTYPE Par_EnumSub(IExplorerCommand *This, IEnumExplorerCommand **ppEnum) {
    (void)This;
    SubCmdEnum *e = CreateEnum();
    if (!e) { *ppEnum = NULL; return E_OUTOFMEMORY; }
    *ppEnum = (IEnumExplorerCommand *)e;
    return S_OK;
}

static IExplorerCommandVtbl g_ParVtbl = {
    Par_QI, Par_AddRef, Par_Release,
    Par_GetTitle, Par_GetIcon, Par_GetToolTip,
    Par_GetCanonicalName, Par_GetState, Par_Invoke,
    Par_GetFlags, Par_EnumSub
};

/* ═══════════════════════════════════════════════════════════════════════
   IClassFactory
   ═══════════════════════════════════════════════════════════════════════ */

typedef struct { IClassFactoryVtbl *lpVtbl; } ToolFactory;

static HRESULT STDMETHODCALLTYPE CF_QI(IClassFactory *This, REFIID riid, void **ppv) {
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) {
        *ppv = This; return S_OK;
    }
    *ppv = NULL; return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE CF_AddRef(IClassFactory *This)  { (void)This; return 2; }
static ULONG STDMETHODCALLTYPE CF_Release(IClassFactory *This) { (void)This; return 1; }

static HRESULT STDMETHODCALLTYPE CF_CreateInstance(IClassFactory *This,
    IUnknown *pOuter, REFIID riid, void **ppv)
{
    (void)This;
    if (pOuter) return CLASS_E_NOAGGREGATION;
    ParentCmd *cmd = (ParentCmd *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(ParentCmd));
    if (!cmd) return E_OUTOFMEMORY;
    cmd->lpVtbl   = &g_ParVtbl;
    cmd->refCount = 1;
    InterlockedIncrement(&g_dllRef);
    HRESULT hr = cmd->lpVtbl->QueryInterface((IExplorerCommand *)cmd, riid, ppv);
    cmd->lpVtbl->Release((IExplorerCommand *)cmd);
    return hr;
}

static HRESULT STDMETHODCALLTYPE CF_LockServer(IClassFactory *This, BOOL fLock) {
    (void)This;
    if (fLock) InterlockedIncrement(&g_dllRef); else InterlockedDecrement(&g_dllRef);
    return S_OK;
}

static IClassFactoryVtbl g_CFVtbl = { CF_QI, CF_AddRef, CF_Release, CF_CreateInstance, CF_LockServer };
static ToolFactory g_Factory = { &g_CFVtbl };

/* ═══════════════════════════════════════════════════════════════════════
   DLL exports
   ═══════════════════════════════════════════════════════════════════════ */

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (IsEqualCLSID(rclsid, &CLSID_Tool))
        return CF_QI((IClassFactory *)&g_Factory, riid, ppv);
    *ppv = NULL;
    return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow(void) {
    return g_dllRef == 0 ? S_OK : S_FALSE;
}
