use std::ffi::{CStr, CString};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::os::raw::c_char;
use pyo3::prelude::*;
use serde_json::json;

static SESSIONS: OnceLock<Mutex<HashMap<String, Py<PyAny>>>> = OnceLock::new();
static BACKEND_PATH: OnceLock<String> = OnceLock::new();

type WorkspaceCallback = unsafe extern "C" fn(session_id: *const c_char, variables_json: *const c_char);
type EventCallback = unsafe extern "C" fn(session_id: *const c_char, event_type: *const c_char, data_json: *const c_char);
static WORKSPACE_CALLBACK: Mutex<Option<WorkspaceCallback>> = Mutex::new(None);
static EVENT_CALLBACK: Mutex<Option<EventCallback>> = Mutex::new(None);

fn get_sessions_map() -> &'static Mutex<HashMap<String, Py<PyAny>>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_set_event_callback(callback: EventCallback) {
    let mut cb = EVENT_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_set_workspace_callback(callback: WorkspaceCallback) {
    let mut cb = WORKSPACE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_init(backend_path: *const c_char) -> i32 {
    if backend_path.is_null() {
        return -1;
    }
    
    // Set bridge mode by default for FFI initialization
    unsafe {
        std::env::set_var("UNILAB_BRIDGE_MODE", "1");
    }

    #[cfg(target_os = "linux")]
    unsafe {
        let libs = [
            "libpython3.13.so.1.0\0",
            "libpython3.12.so.1.0\0",
            "libpython3.11.so.1.0\0",
            "libpython3.10.so.1.0\0",
            "libpython3.so\0",
        ];
        for lib in libs {
            if !libc::dlopen(lib.as_ptr() as *const _, libc::RTLD_GLOBAL | libc::RTLD_NOW).is_null() {
                break;
            }
        }
    }

    let catch_result = std::panic::catch_unwind(|| {
        let path_str = unsafe { CStr::from_ptr(backend_path) }
            .to_string_lossy()
            .to_string();
        
        // Convert to absolute path
        let abs_backend_parent = std::path::Path::new(&path_str).canonicalize().unwrap_or_else(|_| std::path::PathBuf::from(&path_str));
        let abs_path_str = abs_backend_parent.to_string_lossy().to_string();

        BACKEND_PATH.set(abs_path_str.clone()).ok();
        let _ = get_sessions_map();

        unsafe {
            std::env::set_var("UNILAB_WEB_MODE", "1");
            std::env::set_var("UNILAB_BRIDGE_MODE", "1");
        }

        Python::with_gil(|py| {
            if let Ok(m) = py.import("matplotlib") {
                let _ = m.call_method1("use", ("Agg",));
            }

            let sys = py.import("sys")?;
            let pypath = sys.getattr("path")?;

            // 1. Add the directory containing 'backend/'
            pypath.call_method1("insert", (0, &abs_path_str))?;

            // 2. Discover and add virtualenv site-packages to sys.path
            let mut venv_paths = vec![
                std::path::PathBuf::from("/opt/unilab/venv"),
                abs_backend_parent.join("venv"),
            ];
            if let Some(parent) = abs_backend_parent.parent() {
                venv_paths.push(parent.join("venv"));
                if let Some(gp) = parent.parent() {
                    if let Some(ggp) = gp.parent() {
                        if let Some(gggp) = ggp.parent() {
                            venv_paths.push(gggp.join("venv"));
                        }
                    }
                }
            }

            for venv_path in venv_paths {
                let venv_lib = venv_path.join("lib");
                if venv_lib.exists() {
                    if let Ok(entries) = std::fs::read_dir(&venv_lib) {
                        for entry in entries.flatten() {
                            let path = entry.path();
                            if path.is_dir() {
                                let site_packages = path.join("site-packages");
                                if site_packages.exists() {
                                    if let Some(sp_str) = site_packages.to_str() {
                                        pypath.call_method1("insert", (0, sp_str))?;
                                        println!("[UniLab-Rust] Added site-packages to sys.path: {}", sp_str);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Debug: print sys.path
            if let Ok(path_list) = pypath.extract::<Vec<String>>() {
                println!("[UniLab-Rust] Python sys.path: {:?}", path_list);
            }
            if let Ok(cwd) = std::env::current_dir() {
                println!("[UniLab-Rust] Current directory: {:?}", cwd);
            }

            PyResult::Ok(())
        }).is_ok()
    });

    match catch_result {
        Ok(true) => 0,
        _ => -1,
    }
}

fn import_module<'py>(py: Python<'py>, module_name: &str) -> PyResult<Bound<'py, PyModule>> {
    match py.import(module_name) {
        Ok(m) => Ok(m),
        Err(original_err) => {
            let relative_name = if module_name.starts_with("backend.") {
                &module_name[8..]
            } else {
                module_name
            };
            match py.import(relative_name) {
                Ok(m) => Ok(m),
                Err(_) => Err(original_err),
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_create_session(username: *const c_char) -> *mut c_char {
    if username.is_null() {
        let err = json!({"error": "username is null"}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let username_str = unsafe { CStr::from_ptr(username) }
            .to_string_lossy()
            .to_string();

        let session_id = uuid::Uuid::new_v4().to_string();
        let workspace = std::env::temp_dir().join(format!("unilab_{}", session_id));
        let workspace_str = workspace.to_string_lossy().to_string();
        let _ = std::fs::create_dir_all(&workspace);

        Python::with_gil(|py| -> Result<String, String> {
            let time_mod = py.import("time").map_err(|e| e.to_string())?;
            let started_at: f64 = time_mod.call_method0("time").map_err(|e| e.to_string())?.extract().map_err(|e| e.to_string())?;

            let pathlib = py.import("pathlib").map_err(|e| e.to_string())?;
            let workspace_py = pathlib.getattr("Path").map_err(|e| e.to_string())?.call1((&workspace_str,)).map_err(|e| e.to_string())?;

            let models_mod = import_module(py, "backend.core.models").map_err(|e| e.to_string())?;
            let session_info_cls = models_mod.getattr("SessionInfo").map_err(|e| e.to_string())?;

            let session_info = session_info_cls.call1((
                session_id.as_str(),
                username_str.as_str(),
                "transpiler",
                started_at,
                workspace_py,
            )).map_err(|e| e.to_string())?;

            let engine_mod = import_module(py, "backend.core.engines.transpiler").map_err(|e| e.to_string())?;
            let engine_cls = engine_mod.getattr("TranspilerEngine").map_err(|e| e.to_string())?;
            let engine = engine_cls.call1((session_info,)).map_err(|e| e.to_string())?;

            let py_session_id = session_id.clone();
            let on_changed = pyo3::types::PyCFunction::new_closure(py, None, None, move |args, _kwargs| {
                let py = args.py();
                let variables = args.get_item(0).unwrap();
                
                let variables_json = (|| {
                    let json_mod = py.import("json").ok()?;
                    let vars_json: String = json_mod
                        .call_method1("dumps", (variables,))
                        .ok()?
                        .extract()
                        .ok()?;
                    Some(vars_json)
                })().unwrap_or_else(|| "{}".to_string());

                if let Some(cb) = *WORKSPACE_CALLBACK.lock().unwrap() {
                    let c_sid = CString::new(py_session_id.clone()).unwrap();
                    let c_json = CString::new(variables_json).unwrap();
                    unsafe {
                        cb(c_sid.into_raw(), c_json.into_raw());
                    }
                }
                Ok::<PyObject, PyErr>(py.None())
            }).map_err(|e| e.to_string())?;

            let py_session_id_event = session_id.clone();
            let on_event = pyo3::types::PyCFunction::new_closure(py, None, None, move |args, _kwargs| {
                let py = args.py();
                let event_type: String = args.get_item(0).unwrap().extract().unwrap();
                let data_json: String = args.get_item(1).unwrap().extract().unwrap();
                
                if let Some(cb) = *EVENT_CALLBACK.lock().unwrap() {
                    let c_sid = CString::new(py_session_id_event.clone()).unwrap();
                    let c_type = CString::new(event_type).unwrap();
                    let c_json = CString::new(data_json).unwrap();
                    unsafe {
                        cb(c_sid.into_raw(), c_type.into_raw(), c_json.into_raw());
                    }
                }
                Ok::<PyObject, PyErr>(py.None())
            }).map_err(|e| e.to_string())?;

            engine.setattr("on_event", on_event).map_err(|e| e.to_string())?;
            engine.setattr("on_workspace_changed", on_changed).map_err(|e| e.to_string())?;

            let mut sessions = get_sessions_map().lock().unwrap();
            sessions.insert(session_id.clone(), engine.into());

            Ok(json!({
                "session_id": session_id,
                "success": true
            }).to_string())
        })
    });

    let json_result = match result {
        Ok(Ok(json)) => json,
        Ok(Err(e)) => json!({"success": false, "error": format!("Python error: {}", e)}).to_string(),
        Err(_) => json!({"success": false, "error": "Failed to create session (panic)"}).to_string(),
    };

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_transpile(code: *const c_char) -> *mut c_char {
    if code.is_null() {
        let err = json!({"success": false, "error": "code is null"}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let code_str = unsafe { CStr::from_ptr(code) }
            .to_string_lossy()
            .to_string();

        Python::with_gil(|py| -> Result<String, String> {
            let transpiler_mod = import_module(py, "backend.core.transpiler_core").map_err(|e| e.to_string())?;
            let transpiler_cls = transpiler_mod.getattr("UniLabTranspiler").map_err(|e| e.to_string())?;
            let transpiler = transpiler_cls.call0().map_err(|e| e.to_string())?;

            let py_result = transpiler.call_method1("transpile", (code_str,)).map_err(|e| e.to_string())?;

            let python_code: String = py_result.get_item(0).unwrap().extract().map_err(|e| e.to_string())?;

            let result = json!({
                "success": true,
                "python_code": python_code
            });
            Ok(result.to_string())
        })
    });

    let json_result = match result {
        Ok(Ok(json)) => json,
        Ok(Err(e)) => json!({"success": false, "error": e}).to_string(),
        Err(_) => json!({"success": false, "error": "Transpilation failed (panic)"}).to_string(),
    };

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_execute(
    session_id: *const c_char,
    code: *const c_char,
    timeout: f64,
) -> *mut c_char {
    if session_id.is_null() || code.is_null() {
        let err = json!({"success": false, "error": "null pointer"}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();
        let code_str = unsafe { CStr::from_ptr(code) }
            .to_string_lossy()
            .to_string();

        Python::with_gil(|py| -> Result<String, String> {
            let sessions = get_sessions_map().lock().unwrap();
            let engine = sessions.get(&session_id_str)
                .ok_or_else(|| "Session not found".to_string())?;
            let engine = engine.bind(py);

            let py_result = engine.call_method1("run_code_sync", (&code_str, timeout)).map_err(|e| e.to_string())?;

            let dataclasses = py.import("dataclasses").map_err(|e| e.to_string())?;
            let result_dict = dataclasses.call_method1("asdict", (py_result,)).map_err(|e| e.to_string())?;

            let json_mod = py.import("json").map_err(|e| e.to_string())?;
            let json_str = json_mod
                .call_method1("dumps", (result_dict,)).map_err(|e| e.to_string())?
                .extract::<String>().map_err(|e| e.to_string())?;

            Ok(json_str)
        })
    });

    let json_result = match result {
        Ok(Ok(json)) => json,
        Ok(Err(e)) => json!({"success": false, "error": e, "stderr": format!("Python Error: {}", e)}).to_string(),
        Err(_) => json!({"success": false, "error": "Execution failed (panic)"}).to_string(),
    };

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_execute_with_filename(
    session_id: *const c_char,
    code: *const c_char,
    filename: *const c_char,
    timeout: f64,
) -> *mut c_char {
    if session_id.is_null() || code.is_null() {
        let err = json!({"success": false, "error": "null pointer"}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();
        let code_str = unsafe { CStr::from_ptr(code) }
            .to_string_lossy()
            .to_string();
        let filename_str = if filename.is_null() {
            None
        } else {
            Some(unsafe { CStr::from_ptr(filename) }.to_string_lossy().to_string())
        };

        Python::with_gil(|py| -> Result<String, String> {
            let sessions = get_sessions_map().lock().unwrap();
            let engine = sessions.get(&session_id_str)
                .ok_or_else(|| "Session not found".to_string())?;
            let engine = engine.bind(py);

            let py_result = engine.call_method1("run_code_sync", (&code_str, timeout, filename_str)).map_err(|e| e.to_string())?;

            let dataclasses = py.import("dataclasses").map_err(|e| e.to_string())?;
            let result_dict = dataclasses.call_method1("asdict", (py_result,)).map_err(|e| e.to_string())?;

            let json_mod = py.import("json").map_err(|e| e.to_string())?;
            let json_str = json_mod
                .call_method1("dumps", (result_dict,)).map_err(|e| e.to_string())?
                .extract::<String>().map_err(|e| e.to_string())?;

            Ok(json_str)
        })
    });

    let json_result = match result {
        Ok(Ok(json)) => json,
        Ok(Err(e)) => json!({"success": false, "error": e, "stderr": format!("Python Error: {}", e)}).to_string(),
        Err(_) => json!({"success": false, "error": "Execution failed (panic)"}).to_string(),
    };

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_get_workspace(session_id: *const c_char) -> *mut c_char {
    if session_id.is_null() {
        let err = json!({"variables": {}}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();

        Python::with_gil(|py| -> Result<String, String> {
            let sessions = get_sessions_map().lock().unwrap();
            let engine = sessions.get(&session_id_str)
                .ok_or_else(|| "Session not found".to_string())?;
            let engine = engine.bind(py);

            let vars_dict = engine.call_method0("_get_variables").map_err(|e| e.to_string())?;

            let json_mod = py.import("json").map_err(|e| e.to_string())?;
            let vars_json = json_mod
                .call_method1("dumps", (vars_dict,)).map_err(|e| e.to_string())?
                .extract::<String>().map_err(|e| e.to_string())?;

            Ok(vars_json)
        })
    });

    let json_result = match result {
        Ok(Ok(json)) => format!("{{\"variables\": {}}}", json),
        Ok(Err(e)) => json!({"variables": {}, "error": e}).to_string(),
        Err(_) => json!({"variables": {}}).to_string(),
    };

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_get_autocomplete(
    session_id: *const c_char,
    text: *const c_char,
    line: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || text.is_null() || line.is_null() {
        let err = json!({"suggestions": []}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();
        let text_str = unsafe { CStr::from_ptr(text) }
            .to_string_lossy()
            .to_string();
        let line_str = unsafe { CStr::from_ptr(line) }
            .to_string_lossy()
            .to_string();

        Python::with_gil(|py| {
            let sessions = get_sessions_map().lock().unwrap();
            let engine = sessions.get(&session_id_str)?.bind(py);

            let suggestions: Vec<String> = engine
                .call_method1("complete", (text_str.clone(), line_str.clone()))
                .ok()?
                .extract()
                .ok()?;

            let result = json!({
                "suggestions": suggestions
            });
            Some(result.to_string())
        })
    });

    let json_result = result
        .ok()
        .flatten()
        .unwrap_or_else(|| json!({"suggestions": []}).to_string());

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_list_files(session_id: *const c_char) -> *mut c_char {
    if session_id.is_null() {
        let err = json!({"files": []}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();

        let workspace_path = std::env::temp_dir().join(format!("unilab_{}", session_id_str));
        let workspace_path_str = workspace_path.to_string_lossy().to_string();
        let mut files = Vec::new();

        if let Ok(entries) = std::fs::read_dir(&workspace_path) {
            for entry in entries.flatten() {
                if let Ok(metadata) = entry.metadata() {
                    let name = entry
                        .file_name()
                        .to_string_lossy()
                        .to_string();
                    let path = entry
                        .path()
                        .to_string_lossy()
                        .to_string();
                    let size = metadata.len();
                    let is_directory = metadata.is_dir();

                    files.push(json!({
                        "name": name,
                        "path": path,
                        "size": size,
                        "is_directory": is_directory
                    }));
                }
            }
        }

        let result = json!({
            "files": files,
            "total": files.len(),
            "path": workspace_path_str
        });
        Some(result.to_string())
    });

    let json_result = result
        .ok()
        .flatten()
        .unwrap_or_else(|| json!({"files": []}).to_string());

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_create_file(
    session_id: *const c_char,
    filename: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || filename.is_null() || content.is_null() {
        let err = json!({"success": false, "error": "null pointer"}).to_string();
        return CString::new(err).unwrap().into_raw();
    }

    let result = std::panic::catch_unwind(|| {
        let session_id_str = unsafe { CStr::from_ptr(session_id) }
            .to_string_lossy()
            .to_string();
        let filename_str = unsafe { CStr::from_ptr(filename) }
            .to_string_lossy()
            .to_string();
        let content_str = unsafe { CStr::from_ptr(content) }
            .to_string_lossy()
            .to_string();

        let workspace_path = std::env::temp_dir().join(format!("unilab_{}", session_id_str));
        let file_path = workspace_path.join(&filename_str);

        std::fs::write(&file_path, &content_str).ok()?;

        let result = json!({
            "success": true,
            "path": file_path.to_string_lossy().to_string()
        });
        Some(result.to_string())
    });

    let json_result = result
        .ok()
        .flatten()
        .unwrap_or_else(|| json!({"success": false, "error": "Failed to create file"}).to_string());

    CString::new(json_result).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_ping() -> i32 {
    Python::with_gil(|py| {
        match py.import("sys") {
            Ok(_) => 0,
            Err(_) => -1,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn unilab_send_sim_event(event_json: *const c_char) {
    if event_json.is_null() {
        return;
    }

    let event_str = unsafe { CStr::from_ptr(event_json) }
        .to_string_lossy()
        .to_string();

    Python::with_gil(|py| {
        if let Ok(sim_mod) = import_module(py, "backend.core.simulation.engine") {
            if let Ok(push_func) = sim_mod.getattr("push_sim_event") {
                let _ = push_func.call1((event_str,));
            }
        }
    });
}