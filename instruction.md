# **POC TODO: APK Extractor (MacCatalyst + SwiftUI, Library-Only Approach)**

## **0. Final Constraints (Locked)**

* ❌ No system dependency (`apkanalyzer`, `sdkmanager`)
* ❌ No custom parsing (AXML decoding, binary parsing)
* ❌ No low-level scripting
* ✅ Only **well-known libraries**
* ✅ Bundle everything inside app

---

# **1. Recommended Library Stack**

## **Primary Choice (Best Fit)**

### **Android Asset Packaging Tool (AAPT2) – Embedded Binary**

* Industry-standard tool used by Android build system
* Handles:

  * Manifest parsing
  * Resource decoding
  * Icon resolution
* More stable than apkanalyzer for bundled usage

👉 Treat it as an **embedded library/tool**, not system dependency

---

## **Alternative (If avoiding binaries completely)**

### **Option: APK Parser Libraries**

You can embed prebuilt libraries like:

* **`net.dongliu:apk-parser`**
* **`com.google.android:apkanalyzer` (library form)**

⚠️ But:

* These are **Java libraries**, not native Swift
* You still need a **Java runtime or bridge**

👉 So practically:

* Either **bundle Java runtime**
* Or use **native binary like AAPT2**

---

# **2. Final Recommendation**

### ✅ **Use AAPT2 (Bundled Binary)**

Why:

* No custom parsing
* No Java dependency
* Stable output
* Widely used in production

---

# **3. Bundle Tool Inside App**

## **3.1 Add AAPT2 Binary**

* [ ] Download `aapt2` (macOS version)
* [ ] Place in:

```
/Resources/Tools/aapt2
```

## **3.2 Make Executable**

* [ ] Ensure:

```bash
chmod +x aapt2
```

## **3.3 Xcode Setup**

* [ ] Add to **Copy Bundle Resources**
* [ ] Verify runtime path:

```swift
Bundle.main.path(forResource: "aapt2", ofType: nil)
```

---

# **4. APK Processing via AAPT2**

## **4.1 Extract Metadata**

```bash
aapt2 dump badging app.apk
```

Provides:

* Package name
* Version info
* SDK levels
* Permissions
* Icon reference

---

## **4.2 Extract Permissions**

```bash
aapt2 dump permissions app.apk
```

---

## **4.3 Extract Manifest (Readable)**

```bash
aapt2 dump xmltree app.apk AndroidManifest.xml
```

---

# **5. Swift Integration Layer**

## **5.1 Service Layer**

* [ ] `APKExtractionService`
* [ ] Use `Process` to invoke bundled `aapt2`

## **5.2 Responsibilities**

* Execute commands
* Capture stdout
* Return structured response

---

# **6. Parsing Strategy (Still High-Level)**

Even though parsing is needed:

* ✅ Only parse **plain text output**
* ❌ No binary parsing

Example:

```
package: name='com.example.app' versionCode='12'
```

→ Safe string parsing

---

# **7. Model Definition**

```swift
struct APKMetadata {
    let packageName: String
    let versionName: String
    let versionCode: String
    let permissions: [String]
    let minSDK: String
    let targetSDK: String
    let iconPath: String?
}
```

---

# **8. Icon Extraction Strategy**

## **Step 1**

* Get icon path from:

```
application-icon-xxx:'res/mipmap-xxx/ic_launcher.png'
```

## **Step 2**

* Unzip APK (ZIP archive)

## **Step 3**

* Extract matching icon file

## **Step 4**

* Convert to `NSImage`

---

# **9. UI Flow**

* [ ] Select APK (Document Picker)
* [ ] Run extraction
* [ ] Display:

  * Icon
  * Package info
  * Version
  * Permissions list

---

# **10. Sandbox Considerations**

* [ ] Copy APK into:

  * App temp directory
* [ ] Execute tools only on internal paths

---

# **11. Error Handling**

* [ ] Tool missing in bundle
* [ ] Execution failure
* [ ] Invalid APK
* [ ] Unsupported APK format

---

# **12. Testing Matrix**

* [ ] Debug APK
* [ ] Release APK
* [ ] Large apps
* [ ] Apps with adaptive icons

---

# **13. Deliverables**

* [ ] Working MacCatalyst app
* [ ] Embedded `aapt2`
* [ ] Clean service abstraction
* [ ] README:

  * No external dependency
  * Fully offline working

---

# **⚡ Final Architecture**

```
SwiftUI
   ↓
ViewModel
   ↓
APKExtractionService
   ↓
Bundled AAPT2 (binary)
   ↓
APK File
```

---

# **⚖️ Decision Summary**

| Approach          | Status                         |
| ----------------- | ------------------------------ |
| apkanalyzer + SDK | ❌ Rejected (system dependency) |
| Custom parsing    | ❌ Rejected (low-level)         |
| Java libraries    | ⚠️ Adds runtime complexity     |
| **AAPT2 bundled** | ✅ Best fit                     |

---