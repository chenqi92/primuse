import Foundation

public enum WiFiTransferPage {
    public static let english: [String: String] = [
        "addMusic": "Add music",
        "librarySelectionHint": "Choose songs from local music or connected sources. Files, lyrics and artwork are prepared before sending.",
        "libraryProtected": "Apple Music subscription tracks cannot be exported as audio files.",
        "librarySourceUnavailable": "This source is unavailable. Enable or reconnect it, then try again.",
        "libraryCue": "This is a CUE track. Use Choose files to send the complete audio and CUE sheet together.",
        "libraryStream": "Live streams and STRM links cannot be sent as audio files.",
        "libraryUnknownSize": "The original file size is unknown. Refresh this music source, then try again.",
        "libraryPreparing": "Preparing music…",
        "libraryPrepared": "Music added to the send queue",
        "libraryPreparationDetail": "%d / %d songs · %@",
        "libraryLyricsUnavailable": "Lyrics could not be prepared. The audio is still ready to send.",
        "libraryCoverUnavailable": "Artwork could not be prepared. The audio is still ready to send.",
        "librarySourceChanged": "The song or source changed during preparation. Select it again.",
        "libraryAllSources": "All sources",
        "librarySearch": "Search songs, artists or albums",
        "libraryEmpty": "No matching songs",
        "libraryAlreadyAdded": "Already in the send queue",
        "libraryAddSelected": "Add %d songs",
        "libraryRetryPreparation": "Retry preparing failed songs",
        "libraryChooseMusic": "Choose music to send",

        "receiveHistory": "Earlier transfers",
        "receiveTimedOut": "The sending device stopped responding. Completed files are kept; retry the remaining files.",
        "backgroundStopped": "Transfer stopped because Primuse went into the background. Completed files are kept. Start receiving again to get a new code.",
        "closeSenderHint": "Sending will stop. Files already received on the other device are kept.",
        "closeReceiverHint": "Receiving will stop and this access code will expire. Completed files are kept; unfinished files must be sent again.",
        "keepTransferring": "Keep transferring",
        "stopAndClose": "Stop and close",
        "stopReceiveTitle": "Stop receiving?",
        "closeTransferTitle": "Stop transfer and close?",
        "receiveRecentFiles": "Showing the 20 most recent files.",
        "receiveFileDetails": "File details",
        "receiveStored": "Files saved and music library updated.",
        "receiveWaitingFiles": "Waiting for the next file…",
        "browserSender": "Web browser",
        "receiveCount": "%ld / %ld files",
        "receiveIncomplete": "Some files were not received. Completed files are kept; retry the remaining files on the sender.",
        "receiveInterrupted": "Transfer incomplete",
        "receiveCompleted": "Received successfully",
        "receiveActivity": "Receive activity",
        "folderType": "Folder",
        "sendFilesTitle": "Music to send",
        "manualConnection": "Connect manually",
        "receiverReady": "Waiting for a sending device",
        "receiveEmptyTitle": "Bring your music here",
        "receiveEmptyHint": "Receive music, lyrics and artwork, then find them in your local library.",
        "sameNetwork": "Same local network",
        "webSubtitle": "Manage your local music from a browser",
        "webIntro": "Your music, in Primuse",
        "connectTitle": "Connect to Primuse",
        "webConnectHint": "Enable Browser access on the receiving device. Its transfer screen shows the access code.",
        "searchFiles": "Search this folder",
        "noMatches": "No matching files",
        "sessionHint": "Keep Primuse in the foreground. Moving it to the background stops transfer; completed files are kept.",
        "title": "Wi-Fi transfer", "subtitle": "Send music to Primuse from your browser.",
        "scope": "Manage files copied into Primuse’s local music folder. Keep the app open on the same network.",
        "code": "Access code", "codeHint": "Enter the six-digit code shown in Primuse.", "connect": "Connect",
        "files": "Choose files", "folder": "Choose folder", "drop": "Drop music or folders here",
        "formats": "Audio, LRC / TTML lyrics, CUE sheets and cover images. Folders keep their structure.",
        "root": "Local music", "refresh": "Refresh", "newFolder": "New folder", "folderName": "Folder name",
        "name": "Name", "size": "Size", "delete": "Delete", "empty": "No files here yet. Choose files or a folder to upload.",
        "deleteConfirm": "Delete this file from Primuse? This cannot be undone.",
        "deleteFolderConfirm": "Delete this empty folder? Nonempty folders must be cleared first.",
        "cancel": "Cancel", "uploading": "Uploading", "uploaded": "Uploaded", "failed": "Failed", "skipped": "Skipped",
        "finished": "Transfer complete", "cancelled": "Transfer stopped. Completed files are kept.",
        "disconnect": "Disconnect", "connected": "Connected", "waiting": "Connecting…",
        "invalidPath": "Use a regular file or folder name without hidden or parent paths.",
        "unsupportedFile": "This file format is not supported.",
        "conflict": "This name already exists, a transfer is busy, or the folder is not empty. Nothing was replaced.",
        "notFound": "This file or folder is no longer available. Refresh the list.",
        "notEnoughSpace": "There is not enough free space on the device.",
        "invalidRequest": "The upload is empty or incomplete. Select the file again.",
        "tooLarge": "The maximum file size is 8 GB.", "unauthorized": "The code is incorrect or the session has ended.",
        "tooManyAttempts": "Too many incorrect codes. Wait 30 seconds and try again.",
        "unavailable": "Connection lost. Keep Primuse open and check that both devices use the same network.",
        "start": "Start transfer", "stop": "Stop transfer", "address": "Browser address",
        "openAddress": "Open this address in a browser on another device.",
        "copyAddress": "Copy address", "copied": "Address copied",
        "sessionCode": "This code only works while this transfer session is open.",
        "stored": "Completed files appear in Local music after the library refreshes.",
        "keepOpen": "Keep this screen open. Transfer stops when you leave it or send Primuse to the background. Use a trusted Wi-Fi or wired local network.",
        "network": "Connect to Wi-Fi or Ethernet and allow Primuse to access your local network in Settings.",
        "enableSource": "Enable the Local music source before starting a transfer.",
        "nativeTitle": "Device transfer",
        "nativeSubtitle": "Send music, lyrics and folders to another Primuse device on your local network.",
        "send": "Send to a device",
        "receive": "Receive files",
        "receiveHint": "Start receiving, then choose this device in Primuse on the sending device. Enter this code and approve the request here.",
        "browserAccess": "Browser access",
        "browserHint": "Upload and manage local files from a browser on another device. App-to-app transfers work independently.",
        "nearby": "Nearby devices",
        "noDevices": "No receiving devices found",
        "discoveryHint": "Open Receive files on the other device. Use the same local network and allow local network access. You can also enter its address manually.",
        "manualAddress": "Receiver address (IP:port)",
        "localFiles": "Music imported on this device",
        "selected": "Selected files",
        "preparing": "Preparing files…",
        "sendNow": "Start sending",
        "waitingApproval": "Waiting for the receiver to accept…",
        "accept": "Accept",
        "decline": "Decline",
        "requestTitle": "Receive this transfer?",
        "requestSummary": "%@ wants to send %ld files (%@).",
        "receiving": "Receiving",
        "sending": "Sending",
        "stopReceiving": "Stop receiving",
        "startReceiving": "Start receiving",
        "retry": "Retry failed files",
        "remove": "Remove from selection",
        "done": "Done",
        "emptySelection": "Choose music files or a folder to send.",
        "sent": "Sent",
        "indexing": "Updating the music library…",
        "tvStorage": "Received music plays directly on this Apple TV. tvOS may reclaim local files when storage is low; keep the originals so you can send them again.",
        "library": "View received music",
        "enabled": "On",
        "disabled": "Off",
        "browserDisabled": "Browser access is off. Enable it on the receiving device.",
        "rejected": "The receiving device declined the transfer.",
        "invalidAddress": "Enter the receiver’s local IPv4 address and port, for example 192.168.1.8:12345, and its six-digit code."
    ]

    public static func html(strings: [String: String] = [:], language: String = "en") -> String {
        var labels = english.merging(strings) { _, new in new }
        labels["pageLanguage"] = language
        let json = (try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys])) ?? Data()
        let encoded = (String(data: json, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        let extensions = WiFiTransferFiles.extensions.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        let htmlLanguage = language.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let rightToLeft = htmlLanguage.split(separator: "-").first?.lowercased() == "ar"
        return template.replacingOccurrences(of: "__LABELS__", with: encoded)
            .replacingOccurrences(of: "__EXTENSIONS__", with: extensions)
            .replacingOccurrences(of: "__LANGUAGE__", with: htmlLanguage.isEmpty ? "en" : htmlLanguage)
            .replacingOccurrences(of: "__DIRECTION__", with: rightToLeft ? "rtl" : "ltr")
    }

    private static let template = #"""
    <!doctype html>
    <html lang="__LANGUAGE__" dir="__DIRECTION__">
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Primuse</title>
    <style>
    :root{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:14px;color-scheme:light dark;--bg:#E7E9ED;--surface:#FFFFFF;--workspace:#F6F7F9;--sidebar:#EDEFF2;--text:#1C1D1F;--muted:#72767D;--line:#DDE0E5;--accent:#C15D3D;--accent-soft:#C15D3D12;--button:#ECEEF2;--danger:#C43E46;--green:#327D51;--shadow:#20242C12}
    @media(prefers-color-scheme:dark){:root{--bg:#0E1013;--surface:#202226;--workspace:#191B1F;--sidebar:#14161A;--text:#EEF0F2;--muted:#9A9EA7;--line:#34373D;--accent:#D87957;--accent-soft:#D879571A;--button:#2B2E34;--danger:#FF969D;--green:#85C89B;--shadow:#0005}}
    *{box-sizing:border-box}body{margin:0;color:var(--text);background:var(--bg)}button,input{font:inherit}button{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:34px;padding:7px 13px;border:1px solid transparent;border-radius:8px;background:var(--button);color:var(--text);font-weight:500;cursor:pointer;transition:background .15s,box-shadow .15s}button:hover{box-shadow:inset 0 0 0 1px var(--line);filter:brightness(.97)}button:active{transform:translateY(1px)}button:disabled{opacity:.4;cursor:default;transform:none}button:focus-visible,input:focus-visible{outline:3px solid var(--accent);outline-offset:3px}.primary{background:var(--accent);color:#fff;font-weight:600}.quiet{background:none}.danger{background:var(--danger);color:#fff}.icon-button{width:34px;padding:7px;background:transparent;color:var(--muted)}svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}input{min-width:0;padding:11px 12px;border:1px solid var(--line);border-radius:8px;background:var(--workspace);color:var(--text)}input::placeholder{color:var(--muted);opacity:.7}
    .app-shell{display:grid;grid-template-columns:214px minmax(0,1fr);width:calc(100% - 48px);max-width:1440px;min-height:calc(100dvh - 48px);margin:24px auto;border:1px solid var(--line);border-radius:18px;overflow:hidden;box-shadow:0 18px 56px var(--shadow);background:var(--workspace)}.sidebar{display:flex;flex-direction:column;padding:29px 18px 24px;background:var(--sidebar);border-inline-end:1px solid var(--line)}.brand{display:flex;align-items:center;gap:11px;padding:0 8px 34px;font-size:21px;font-weight:700;letter-spacing:-.6px}.brand-mark{display:grid;place-items:center;width:36px;height:36px;border-radius:11px;background:var(--accent);color:#fff;box-shadow:0 4px 9px var(--shadow)}.brand-mark svg{width:23px;height:23px;stroke-width:2}.side-item{display:flex;align-items:center;gap:10px;padding:12px;border-radius:9px;background:var(--accent-soft);color:var(--accent);font-weight:600}.side-item svg{width:19px}.side-item .count{margin-inline-start:auto;font-size:12px;font-weight:500;color:var(--muted)}.sidebar-bottom{margin-top:auto;padding:30px 8px 0}.receiver-symbol{width:37px;height:37px;border:1px solid var(--line);border-radius:10px;background:var(--surface);display:grid;place-items:center;margin-bottom:13px}.receiver-symbol svg{width:22px;height:22px}.receiver-label{font-size:11px;color:var(--muted);margin-bottom:6px}.receiver-name{font-size:13px;font-weight:600;overflow-wrap:anywhere;line-height:1.5}.network-label{display:flex;align-items:center;gap:6px;font-size:11px;color:var(--muted);margin-top:10px}.network-label svg{width:13px;height:13px}
    .workspace{min-width:0;display:flex;flex-direction:column}.topbar{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:25px 32px 23px;border-bottom:1px solid var(--line);background:var(--surface)}h1{font-size:23px;letter-spacing:-.6px;line-height:1.25;margin:0;font-weight:650}h2{font-size:18px;letter-spacing:-.3px;line-height:1.4;margin:0;font-weight:600}p{line-height:1.65;margin:0;color:var(--muted)}.subtitle{font-size:12px;margin-top:6px}.connection{display:flex;align-items:center;gap:14px;font-size:12px}.status{display:flex;align-items:center;gap:7px;color:var(--green);white-space:nowrap}.status::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}.connection button{font-size:12px}main{padding:30px 32px;flex:1;min-width:0}
    #welcome{display:grid;grid-template-columns:minmax(0,1fr) 330px;align-items:center;gap:44px;max-width:950px;margin:36px auto 50px}.welcome-copy{padding:0 10px}.device-art{position:relative;width:224px;height:155px;margin-bottom:30px;color:var(--muted)}.device-art .computer{position:absolute;left:0;top:12px;width:184px;height:119px;border:2px solid var(--line);border-radius:12px;background:var(--surface);box-shadow:0 12px 22px var(--shadow)}.device-art .computer::before{content:"";position:absolute;bottom:-20px;left:65px;height:18px;width:46px;border-bottom:3px solid var(--line);border-left:9px solid transparent;border-right:9px solid transparent}.device-art .phone{position:absolute;right:0;bottom:0;width:57px;height:103px;border:2px solid var(--line);border-radius:12px;background:var(--surface);box-shadow:0 7px 16px var(--shadow)}.music-tile{position:absolute;top:28px;left:61px;width:58px;height:58px;display:grid;place-items:center;border-radius:14px;background:var(--accent-soft);color:var(--accent)}.music-tile svg{width:29px;height:29px}.phone svg{position:absolute;width:24px;height:24px;left:14px;top:38px;color:var(--accent)}.welcome-copy h2{font-size:28px;line-height:1.35;letter-spacing:-.7px;margin-bottom:13px}.welcome-copy p{font-size:13px;max-width:37ch}.format-tags{display:flex;flex-wrap:wrap;gap:7px;margin-top:22px}.format-tags span{font-size:10px;font-weight:600;color:var(--muted);padding:5px 8px;border:1px solid var(--line);border-radius:5px;background:var(--surface)}
    #login{background:var(--surface);padding:28px;border:1px solid var(--line);border-radius:15px;box-shadow:0 10px 30px var(--shadow)}.login-icon{width:40px;height:40px;display:grid;place-items:center;border-radius:11px;background:var(--accent-soft);color:var(--accent);margin-bottom:20px}.login-icon svg{width:22px;height:22px}#login h2{margin-bottom:9px}#login p{font-size:12px}#login label{display:block;font-size:12px;font-weight:600;margin:25px 0 10px}#code{direction:ltr;width:100%;text-align:center;font-size:26px;letter-spacing:9px;font-variant-numeric:tabular-nums;padding:14px 8px 14px 17px}#login .primary{width:100%;min-height:42px;margin-top:18px}#login .login-note{margin-top:16px;font-size:11px}
    #notice:empty,#loginNotice:empty{display:none}#login #loginNotice{margin-top:12px;color:var(--danger);font-size:12px}#notice{padding:13px 16px;margin:0 0 18px;border:1px solid color-mix(in srgb,var(--danger) 30%,transparent);border-radius:9px;background:color-mix(in srgb,var(--danger) 6%,var(--surface));color:var(--danger);white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}#drop{display:flex;align-items:center;gap:20px;border:1px dashed var(--line);border-radius:13px;padding:24px;background:var(--surface);transition:border-color .15s,background .15s}#drop.over{background:var(--accent-soft);border-color:var(--accent)}.upload-icon{width:56px;height:62px;display:grid;place-items:center;border:1px solid var(--line);border-radius:11px;flex-shrink:0;background:var(--workspace);color:var(--accent);transform:rotate(-5deg)}.upload-icon svg{width:27px;height:27px}.upload-copy{min-width:0;flex:1}.upload-copy p{font-size:12px;max-width:48ch;margin-top:7px}.actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.upload-actions{flex-shrink:0;flex-direction:column;align-items:stretch}.upload-actions button{font-size:12px;min-height:34px}.toolbar{display:flex;align-items:center;justify-content:space-between;gap:16px;margin:28px 0 15px}#breadcrumbs{display:flex;align-items:center;gap:3px;flex-wrap:wrap;min-width:0}#breadcrumbs button{border:0;background:none;padding:5px 3px;min-height:30px;font-weight:600;text-align:start;overflow-wrap:anywhere;box-shadow:none}#breadcrumbs svg{width:14px;height:14px;color:var(--muted)}#breadcrumbs span{color:var(--muted)}.tools{display:flex;gap:7px;align-items:center;flex-shrink:0}.search-field{display:flex;align-items:center;gap:6px;border:1px solid var(--line);border-radius:8px;padding-inline-start:9px;background:var(--surface)}.search-field svg{width:15px;color:var(--muted)}#searchFiles{width:145px;border:0;background:none;padding:8px;font-size:12px}.tools button{font-size:12px}.file-list{background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden}.row{display:grid;grid-template-columns:minmax(0,1fr) 92px 40px;align-items:center;gap:16px;padding:11px 18px;border-bottom:1px solid var(--line);min-height:58px}.row:last-child{border-bottom:0}.row:not(.heading):hover{background:var(--workspace)}.row.heading{min-height:37px;padding-top:8px;padding-bottom:8px;font-size:11px;color:var(--muted);background:var(--workspace)}.filename{display:flex;gap:12px;align-items:center;min-width:0}.file-icon{display:grid;place-items:center;width:32px;height:36px;border-radius:7px;background:var(--accent-soft);color:var(--accent);flex-shrink:0}.file-icon.folder{background:var(--button);color:var(--muted)}.file-name-text{overflow-wrap:anywhere;min-width:0}.filename button{padding:0;min-height:32px;background:none;box-shadow:none;text-align:start;justify-content:flex-start;font-weight:500}.file-size{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}.delete-file{opacity:.6}.row:hover .delete-file,.delete-file:focus-visible{opacity:1;color:var(--danger)}.mobile-size{display:none}#empty{padding:50px 22px;text-align:center}#empty svg{width:37px;height:37px;color:var(--muted);opacity:.6;margin-bottom:12px}#empty p{font-size:13px}
    #progressBox{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:18px;margin-top:18px}.progress-top{display:flex;gap:16px;align-items:flex-start;justify-content:space-between}#current{font-size:13px;font-weight:600;color:var(--text);overflow-wrap:anywhere}#totals{font-size:12px;margin-top:4px}progress{display:block;width:100%;height:5px;margin-top:14px;border:0;border-radius:99px;overflow:hidden;accent-color:var(--accent)}progress::-webkit-progress-bar{background:var(--button);border-radius:99px}progress::-webkit-progress-value{background:var(--accent);border-radius:99px}#results{font-size:12px;max-height:150px;overflow:auto;color:var(--danger);line-height:1.7;padding-inline-start:18px}#results:empty{display:none}footer{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:16px 32px;border-top:1px solid var(--line);font-size:11px;color:var(--muted)}footer svg{width:13px;height:13px}.footer-note{display:flex;gap:6px;align-items:center}.footer-scope{max-width:65ch;text-align:right;font-size:11px}
    dialog{border:1px solid var(--line);border-radius:16px;padding:28px;width:min(420px,calc(100% - 36px));background:var(--surface);color:var(--text);box-shadow:0 24px 80px #0003}dialog::backdrop{background:#14171D66;backdrop-filter:blur(4px)}dialog h2{margin-bottom:12px}dialog p{font-size:13px;margin-bottom:18px}dialog .actions{justify-content:flex-end;margin-top:24px}#deleteName{font-weight:600;color:var(--text);padding:12px;background:var(--workspace);border-radius:8px;overflow-wrap:anywhere}#folderName{width:100%;margin-top:12px}dialog label{font-size:12px;color:var(--muted)}[hidden]{display:none!important}
    @media(max-width:1150px){.app-shell{grid-template-columns:180px minmax(0,1fr)}#welcome{gap:26px;grid-template-columns:minmax(0,1fr) 290px}.welcome-copy h2{font-size:24px}#login{padding:24px}#drop{flex-wrap:wrap}.upload-actions{flex-direction:row;width:100%;padding-left:76px}.tools .search-field{display:none}}
    @media(max-width:900px){.app-shell{grid-template-columns:1fr;max-width:820px}.sidebar{display:none}#welcome{margin:24px 0 38px}.topbar{padding:23px 26px}main{padding:26px}footer{padding:16px 26px}}
    @media(max-width:620px){:root{font-size:15px}input{font-size:16px}.app-shell{width:100%;margin:0;min-height:100dvh;border:0;border-radius:0;box-shadow:none}.topbar{padding:20px;gap:10px}h1{font-size:21px}.subtitle{font-size:11px;max-width:26ch}.connection{gap:6px}.connection .status{display:none}.connection button{font-size:11px;min-height:44px;padding:7px 9px}main{padding:22px 18px}.welcome-copy{padding:0}.device-art{transform:scale(.75);transform-origin:left bottom;margin-top:-22px;margin-bottom:10px}.welcome-copy h2{font-size:25px}.welcome-copy p{max-width:40ch}.format-tags{margin-top:14px}#welcome{grid-template-columns:1fr;gap:28px;margin:0 0 24px}#login{padding:24px;box-shadow:none}.login-icon{display:none}#login label{margin-top:22px}#login .primary{min-height:46px}.upload-icon{width:44px;height:50px}.upload-copy h2{font-size:17px}.upload-copy p{font-size:11px}#drop{padding:18px;gap:14px}.upload-actions{padding:0;gap:8px}.upload-actions button{flex:1;min-height:44px;font-size:13px}.toolbar{align-items:flex-start;flex-wrap:wrap;gap:10px;margin-top:24px}.tools{width:100%;justify-content:flex-end}.tools .search-field{display:flex;margin-right:auto;min-width:0;flex:1}#searchFiles{width:100%;min-width:30px;min-height:44px;font-size:16px}.tools button{min-height:44px}.tools .icon-button{width:44px;min-width:44px}.row{grid-template-columns:minmax(0,1fr) 44px;gap:8px;padding:10px 12px}.row.heading{grid-template-columns:minmax(0,1fr) 44px}.row .file-size{display:none}.row.heading span:nth-child(2){display:none}.filename{gap:10px;font-size:13px}.mobile-size{display:block;font-size:10px;color:var(--muted);margin-top:4px}.delete-file{width:44px;min-height:44px;opacity:1}#breadcrumbs button,.filename button,dialog button,#cancelUpload{min-width:44px;min-height:44px}.file-icon{width:30px;height:35px}.progress-top{gap:8px}footer{padding:16px 20px;align-items:flex-start}.footer-scope{display:none}}
    @media(prefers-reduced-motion:reduce){*{transition:none!important;scroll-behavior:auto!important}}
    </style>
    <div class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span class="brand-mark"><svg viewBox="0 0 24 24"><path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/></svg></span>Primuse</div>
      <div class="side-item"><svg viewBox="0 0 24 24"><path d="M4 5h16v14H4zM8 9h8M8 13h5"/></svg><span data-text="root"></span><span class="count" id="fileCount"></span></div>
      <div class="sidebar-bottom"><div class="receiver-symbol"><svg viewBox="0 0 24 24"><rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 18h4"/></svg></div><div class="receiver-label" data-text="receive"></div><div class="receiver-name" id="deviceName">Primuse</div><div class="network-label"><svg viewBox="0 0 24 24"><path d="M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0M9 16a5 5 0 0 1 6 0M12 20h.01"/></svg><span data-text="sameNetwork"></span></div></div>
    </aside>
    <div class="workspace">
    <header class="topbar"><div><h1 data-text="title"></h1><p class="subtitle" data-text="webSubtitle"></p></div><div class="connection" id="connection" hidden><span class="status" id="connectedStatus" data-text="connected"></span><button id="disconnect" class="quiet" data-text="disconnect"></button></div></header>
    <main>
    <section id="welcome">
      <div class="welcome-copy"><div class="device-art" aria-hidden="true"><div class="computer"><div class="music-tile"><svg viewBox="0 0 24 24"><path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/></svg></div></div><div class="phone"><svg viewBox="0 0 24 24"><path d="M5 12h14m-5-5 5 5-5 5"/></svg></div></div><h2 data-text="webIntro"></h2><p data-text="receiveEmptyHint"></p><div class="format-tags" aria-label="Formats"><span>FLAC</span><span>MP3</span><span>ALAC</span><span>LRC</span><span>TTML</span><span>CUE</span></div></div>
      <form id="login"><div class="login-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="4" y="10" width="16" height="11" rx="3"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 15v2"/></svg></div><h2 data-text="connectTitle"></h2><p data-text="codeHint"></p><label for="code" data-text="code"></label><input id="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" placeholder="000000" autocomplete="one-time-code" required><button class="primary" id="connectButton" data-text="connect"></button><p id="loginNotice" role="alert"></p><p class="login-note" data-text="webConnectHint"></p></form>
    </section>
    <p id="notice" role="alert"></p>
    <section id="manager" hidden>
      <div id="drop"><div class="upload-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="M7 3h8l4 4v14H5V3zM14 3v5h5M12 17v-6m-3 3 3-3 3 3"/></svg></div><div class="upload-copy"><h2 data-text="drop"></h2><p data-text="formats"></p></div><div class="actions upload-actions"><button class="primary" id="chooseFiles"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg><span data-text="files"></span></button><button id="chooseFolder"><svg viewBox="0 0 24 24"><path d="M3 6h6l2 2h10v12H3z"/></svg><span data-text="folder"></span></button></div><input type="file" multiple id="fileInput" hidden><input type="file" multiple webkitdirectory id="folderInput" hidden></div>
      <div id="progressBox" hidden><div class="progress-top"><div><p id="current" role="status"></p><p id="totals" role="status"></p></div><button id="cancelUpload" data-text="cancel"></button></div><progress id="progress" value="0" max="1"></progress><ul id="results"></ul></div>
      <div class="toolbar"><nav id="breadcrumbs"></nav><div class="tools"><label class="search-field"><svg viewBox="0 0 24 24"><circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/></svg><input id="searchFiles" type="search" data-placeholder="searchFiles"></label><button class="icon-button" id="refresh" data-title="refresh"><svg viewBox="0 0 24 24"><path d="M20 7v5h-5M4 17v-5h5M20 12a8 8 0 0 0-14-5M4 12a8 8 0 0 0 14 5"/></svg></button><button id="newFolder"><svg viewBox="0 0 24 24"><path d="M3 6h6l2 2h10v12H3zM12 11v6M9 14h6"/></svg><span data-text="newFolder"></span></button></div></div>
      <div class="file-list"><div class="row heading"><span data-text="name"></span><span data-text="size"></span><span></span></div><div id="fileList"></div><div id="empty" hidden><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h6l2 2h10v12H3zM12 12v5M10 16h4"/></svg><p data-text="empty"></p></div></div>
    </section>
    </main>
    <footer><span class="footer-note"><svg viewBox="0 0 24 24"><path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6zM8 12l3 3 5-6"/></svg><span data-text="sameNetwork"></span></span><p class="footer-scope" data-text="scope"></p></footer>
    </div></div>
    <dialog id="deleteDialog"><h2 data-text="delete"></h2><p id="deletePrompt"></p><p id="deleteName"></p><div class="actions"><button id="cancelDelete" data-text="cancel"></button><button class="danger" id="confirmDelete" data-text="delete"></button></div></dialog>
    <dialog id="folderDialog"><form id="folderForm"><h2 data-text="newFolder"></h2><label for="folderName" data-text="folderName"></label><input id="folderName" required maxlength="255" autocomplete="off"><div class="actions"><button type="button" id="cancelFolder" data-text="cancel"></button><button class="primary" id="confirmFolder" data-text="newFolder"></button></div></form></dialog>
    <script>
    'use strict';
    const labels=__LABELS__,supported=new Set([__EXTENSIONS__]),$=id=>document.getElementById(id),t=key=>labels[key]||key;
    document.title='Primuse · '+t('title');document.documentElement.lang=labels.pageLanguage;
    document.querySelectorAll('[data-text]').forEach(e=>e.textContent=t(e.dataset.text));
    document.querySelectorAll('[data-title]').forEach(e=>{e.title=t(e.dataset.title);e.setAttribute('aria-label',t(e.dataset.title));});
    document.querySelectorAll('[data-placeholder]').forEach(e=>{e.placeholder=t(e.dataset.placeholder);e.setAttribute('aria-label',t(e.dataset.placeholder));});
    $('breadcrumbs').ariaLabel=t('folder');$('progress').setAttribute('aria-label',t('uploading'));
    let code='',path='',busy=false,cancelled=false,xhr=null,pendingDelete=null,entries=[];
    const message=e=>{const text=e?(e.message||String(e)):'';$('notice').textContent=$('welcome').hidden?text:'';$('loginNotice').textContent=$('welcome').hidden?'':text;};
    const size=n=>new Intl.NumberFormat(labels.pageLanguage,{style:'unit',unit:n>=1048576?'megabyte':'kilobyte',maximumFractionDigits:1}).format(n/(n>=1048576?1048576:1024));
    const join=(a,b)=>a?a+'/'+b:b;
    const icons={folder:'<path d="M3 6h6l2 2h10v12H3z"/>',music:'<path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/>',text:'<path d="M5 3h10l4 4v14H5zM9 9h6M9 13h6M9 17h4"/>',photo:'<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1"/><path d="m3 17 6-5 4 3 4-6 4 5"/>',trash:'<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>'};
    function icon(kind){const e=document.createElementNS('http://www.w3.org/2000/svg','svg');e.setAttribute('viewBox','0 0 24 24');e.setAttribute('aria-hidden','true');e.innerHTML=icons[kind];return e;}
    async function api(method,route,p=path){let response;try{response=await fetch(route+'?path='+encodeURIComponent(p),{method,headers:{'X-Primuse-Code':code},cache:'no-store'});}catch{$('connectedStatus').hidden=true;throw Error(t('unavailable'));}const data=await response.json();if(!response.ok){if([401,403,429,503].includes(response.status))$('connectedStatus').hidden=true;throw Error(t(data.error||'unavailable'));}return data;}
    function button(label,action){const b=document.createElement('button');b.textContent=label;b.onclick=action;return b;}
    function render(){const query=$('searchFiles').value.trim().toLocaleLowerCase(),visible=entries.filter(e=>e.name.toLocaleLowerCase().includes(query));$('fileList').replaceChildren();$('empty').hidden=visible.length>0;$('empty').querySelector('p').textContent=t(query?'noMatches':'empty');$('fileCount').textContent=entries.length;for(const entry of visible){const row=document.createElement('div');row.className='row';const name=document.createElement('div');name.className='filename';const ext=entry.name.split('.').pop().toLowerCase(),kind=entry.isDirectory?'folder':['lrc','ttml','cue'].includes(ext)?'text':['jpg','jpeg','png','webp','heic','bmp'].includes(ext)?'photo':'music';const glyph=document.createElement('span');glyph.className='file-icon '+(entry.isDirectory?'folder':'');glyph.append(icon(kind));const label=document.createElement('div');label.className='file-name-text';if(entry.isDirectory)label.append(button(entry.name,()=>navigate(entry.path)));else label.textContent=entry.name;const compact=document.createElement('span');compact.className='mobile-size';compact.textContent=entry.isDirectory?t('folderType'):size(entry.size);label.append(compact);name.append(glyph,label);const bytes=document.createElement('span');bytes.className='file-size';bytes.textContent=entry.isDirectory?'—':size(entry.size);const remove=button('',()=>{pendingDelete=entry;$('deleteName').textContent=entry.name;$('deletePrompt').textContent=t(entry.isDirectory?'deleteFolderConfirm':'deleteConfirm');$('deleteDialog').showModal();});remove.append(icon('trash'));remove.className='icon-button delete-file';remove.disabled=busy;remove.setAttribute('aria-label',t('delete')+' '+entry.name);row.append(name,bytes,remove);$('fileList').append(row);}}
    async function refresh(){try{entries=await api('GET','/api/files');$('connectedStatus').hidden=false;const crumbs=$('breadcrumbs');crumbs.replaceChildren(button(t('root'),()=>navigate('')));let parent='';for(const part of path.split('/').filter(Boolean)){parent=join(parent,part);const target=parent,divider=document.createElement('span');divider.textContent='/';crumbs.append(divider,button(part,()=>navigate(target)));}render();}catch(e){message(e);throw e;}}
    async function navigate(next){const previous=path;path=next;$('searchFiles').value='';try{await refresh();}catch{path=previous;}}
    $('searchFiles').oninput=render;
    $('login').onsubmit=async e=>{e.preventDefault();message();code=$('code').value;$('connectButton').disabled=true;$('connectButton').textContent=t('waiting');try{await refresh();const info=await api('GET','/api/info','');$('deviceName').textContent=info.identity?.name||'Primuse';$('welcome').hidden=true;$('manager').hidden=false;$('connection').hidden=false;}catch{code='';}finally{$('connectButton').disabled=false;$('connectButton').textContent=t('connect');}};
    $('refresh').onclick=()=>{message();refresh().catch(()=>{});};
    $('disconnect').onclick=()=>{cancelled=true;if(xhr)xhr.abort();code='';path='';entries=[];$('searchFiles').value='';$('fileCount').textContent='';$('deviceName').textContent='Primuse';$('code').value='';$('welcome').hidden=false;$('manager').hidden=true;$('connection').hidden=true;$('progressBox').hidden=true;message();$('code').focus();};
    $('cancelDelete').onclick=()=>$('deleteDialog').close();
    $('confirmDelete').onclick=async()=>{if(!pendingDelete)return;$('confirmDelete').disabled=true;try{await api('DELETE','/api/files',pendingDelete.path);$('deleteDialog').close();message();await refresh();}catch(e){$('deleteDialog').close();message(e);}finally{$('confirmDelete').disabled=false;pendingDelete=null;}};
    $('newFolder').onclick=()=>{$('folderName').value='';$('folderDialog').showModal();$('folderName').focus();};
    $('cancelFolder').onclick=()=>$('folderDialog').close();
    $('folderForm').onsubmit=async e=>{e.preventDefault();const name=$('folderName').value.trim();if(!name)return;$('confirmFolder').disabled=true;try{await api('POST','/api/folders',join(path,name));$('folderDialog').close();message();await refresh();}catch(e){$('folderDialog').close();message(e);}finally{$('confirmFolder').disabled=false;}};
    $('chooseFiles').onclick=()=>$('fileInput').click();$('chooseFolder').onclick=()=>$('folderInput').click();
    $('fileInput').accept=[...supported].map(e=>'.'+e).join(',');
    for(const id of ['fileInput','folderInput']){$(id).onchange=()=>{const files=Array.from($(id).files).map(file=>({file,name:file.webkitRelativePath||file.name}));$(id).value='';upload(files);};}
    $('cancelUpload').onclick=()=>{cancelled=true;if(xhr)xhr.abort();};
    function send(file,target){return new Promise((resolve,reject)=>{const request=new XMLHttpRequest();xhr=request;request.open('PUT','/api/files?path='+encodeURIComponent(target));request.setRequestHeader('X-Primuse-Code',code);request.setRequestHeader('Content-Type','application/octet-stream');request.timeout=0;request.upload.onprogress=e=>{$('progress').value=e.lengthComputable?e.loaded/e.total:0;};request.onload=()=>{xhr=null;let result={};try{result=JSON.parse(request.responseText);}catch{}if(request.status>=200&&request.status<300)resolve();else reject(Error(t(result.error||'unavailable')));};request.onerror=()=>{xhr=null;$('connectedStatus').hidden=true;reject(Error(t('unavailable')));};request.onabort=()=>{xhr=null;reject(Error(t('cancelled')));};request.send(file);});}
    async function upload(files){if(busy||!code||!files.length)return;busy=true;cancelled=false;const destination=path;let done=0,failed=0,skipped=0;message();$('progressBox').hidden=false;$('progress').hidden=false;$('cancelUpload').hidden=false;$('results').replaceChildren();for(const id of ['chooseFiles','chooseFolder','newFolder'])$(id).disabled=true;try{await refresh();for(const item of files){if(cancelled)break;const ext=item.name.split('.').pop().toLowerCase();if(!supported.has(ext)||item.name.split('/').some(p=>p.startsWith('.'))){skipped++;continue;}$('current').textContent=t('uploading')+' '+item.name;$('progress').value=0;try{await send(item.file,join(destination,item.name));done++;}catch(e){if(cancelled)break;failed++;const li=document.createElement('li');li.textContent=item.name+': '+e.message;$('results').append(li);}$('totals').textContent=t('uploaded')+': '+done+' / '+files.length+' · '+t('failed')+': '+failed+' · '+t('skipped')+': '+skipped;}}catch(e){message(e);}finally{busy=false;$('progress').hidden=true;$('cancelUpload').hidden=true;for(const id of ['chooseFiles','chooseFolder','newFolder'])$(id).disabled=false;$('current').textContent=t(cancelled?'cancelled':'finished');$('totals').textContent=t('uploaded')+': '+done+' · '+t('failed')+': '+failed+' · '+t('skipped')+': '+skipped;if(code)await refresh().catch(()=>{});}}
    async function walk(entry,prefix=''){if(entry.isFile)return new Promise((resolve,reject)=>entry.file(file=>resolve([{file,name:join(prefix,file.name)}]),reject));if(!entry.isDirectory)return[];const reader=entry.createReader(),files=[];while(true){const entries=await new Promise((resolve,reject)=>reader.readEntries(resolve,reject));if(!entries.length)break;for(const child of entries)files.push(...await walk(child,join(prefix,entry.name)));}return files;}
    for(const type of ['dragenter','dragover'])$('drop').addEventListener(type,e=>{e.preventDefault();$('drop').classList.add('over');});
    $('drop').ondragleave=()=>$('drop').classList.remove('over');$('drop').ondrop=async e=>{e.preventDefault();$('drop').classList.remove('over');if(busy)return;const items=Array.from(e.dataTransfer.items||[]),entries=items.map(item=>item.webkitGetAsEntry?.()).filter(Boolean);const fallback=Array.from(e.dataTransfer.files).map(file=>({file,name:file.name}));try{let files=[];if(entries.length){for(const entry of entries)files.push(...await walk(entry));}else files=fallback;await upload(files);}catch(e){message(e);}};
    </script></html>
    """#
}
