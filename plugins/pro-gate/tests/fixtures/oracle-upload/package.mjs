// Fixture sources only: no browser, sockets, or installed Oracle imports.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
export const functions = {
  "actions/navigation.js": [
    "navigateToChatGPT",
    "ensureNotBlocked",
    "ensureLoggedIn",
    "ensurePromptReady",
    "ensureChatMode",
    "installJavaScriptDialogAutoDismissal",
    "navigateOnce",
    "attemptWelcomeBackLogin",
    "buildLoginProbeExpression",
    "buildChatModeProbeExpression",
    "waitForPrompt",
    "isCloudflareInterstitial",
  ],
  "actions/promptComposer.js": [
    "clearPromptComposer",
    "dispatchClearEvents",
    "clearEditable",
  ],
  "actions/attachments.js": [
    "clearComposerAttachments",
    "waitForAttachmentCompletion",
    "waitForAttachmentVisible",
    "isAttachmentVisible",
    "buildAttachmentProgressExpression",
    "buildActiveComposerRootExpression",
    "locateComposerRoot",
    "findPromptNode",
  ],
  "actions/modelSelection.js": [
    "ensureModelSelection",
    "buildModelSelectionExpression",
  ],
  "actions/remoteFileTransfer.js": ["uploadAttachmentViaDataTransfer"],
  "actions/attachmentDataTransfer.js": ["transferAttachmentViaDataTransfer"],
  "actions/attachmentEvidence.js": [
    "beginAttachmentEvidence",
    "confirmAttachmentEvidence",
    "buildAttachmentEvidenceExpression",
  ],
  "actions/attachmentContext.js": [
    "captureComposerNavigationUrl",
    "assertComposerPlusStayedInPlace",
    "assertComposerNavigationSnapshot",
    "buildFileInputGuardExpression",
    "buildComposerNavigationProbeExpression",
    "buildComposerNavigationValidationExpression",
  ],
  "focusEmulation.js": [
    "enableFocusEmulation",
    "activateWithoutFocusEmulation",
  ],
  "targetClaim.js": ["claimBrowserTarget"],
  "chromeLifecycle.js": [
    "connectToRemoteChrome",
    "closeRemoteChromeTarget",
    "listRemoteChromeTargets",
  ],
  "utils.js": ["withRetries", "delay"],
  "prompt.js": ["assembleBrowserPrompt"],
};
export function makePackage(root) {
  const put = (p, s) => {
    const dest = path.join(root, p);
    mkdirSync(path.dirname(dest), { recursive: true });
    writeFileSync(dest, s);
  };
  put("package.json", '{"type":"module"}');
  put(
    "dist/src/browser/state.js",
    `
import { EventEmitter } from 'node:events';
import { appendFileSync } from 'node:fs';
export const scenario=process.env.FAKE_SCENARIO;
export const log=(name,args)=>appendFileSync(process.env.FAKE_CALLS,JSON.stringify({name,args})+'\\n');
export const client=new EventEmitter();
let alive=false;
for (const name of ['Network','Page','Runtime','DOM','Fetch']) client[name]={enable:async(args)=>{log(name+'.enable',args); if(name==='Fetch' && scenario==='arm-error') throw Error('arm failed');}};
client.Runtime.evaluate=async()=>({result:{value:'https://chatgpt.com/'}});
client.Fetch.failRequest=async(args)=>log('Fetch.failRequest',args);
client.Fetch.continueRequest=async(args)=>log('Fetch.continueRequest',args);
export async function call(name,...args){
 log(name,args.slice(0,1));
 if(name==='connectToRemoteChrome'){alive=true; return {targetId:'fixture-target',client,close:async()=>{log('close'); if(!['sticky-close','stuck-tab'].includes(scenario)) alive=false;}};}
 if(name==='closeRemoteChromeTarget'){if(scenario!=='stuck-tab') alive=false;return;}
 if(name==='listRemoteChromeTargets') return alive?[{type:'page',targetId:'fixture-target',url:'about:blank'}]:[];
 if(name==='assembleBrowserPrompt' && scenario==='slow-assemble') await new Promise(resolve=>setTimeout(resolve,400));
 if(name==='assembleBrowserPrompt') return {attachmentMode:'upload',composerText:'not typed',attachments:[{path:args[0].file[0],sizeBytes:100}]};
 if(name==='installJavaScriptDialogAutoDismissal') return ()=>{};
 if(name==='isAttachmentVisible' && scenario==='chip-gone') return false;
 if(name==='isAttachmentVisible' && scenario==='probe-error') throw Error('probe failed');
 if(name==='withRetries') return args[0]();
 if(name==='delay') return;
 if(name==='ensureNotBlocked' && scenario==='blocked') throw Error('ChatGPT blocked');
 if(name==='ensureLoggedIn' && scenario==='logged-out') throw Error('logged out');
 if(name==='ensurePromptReady' && scenario==='pre-error') throw Error('composer unavailable');
 if(name==='ensurePromptReady' && scenario==='hang') await new Promise(()=>{});
 if(name==='captureComposerNavigationUrl') return 'https://chatgpt.com/';
 if(name==='navigateToChatGPT'){
   for(const [i,method,p] of [[1,'GET','/backend-api/conversation'],[2,'POST','/backend-api/conversation/init'],[3,'OPTIONS','/backend-api/f/conversation']]) client.emit('Fetch.requestPaused',{requestId:String(i),request:{method,url:'https://chatgpt.com'+p}});
   if(scenario==='send') client.emit('Fetch.requestPaused',{requestId:'send',request:{method:'POST',url:'https://chatgpt.com/backend-api/f/conversation'}});
   if(scenario==='tripwire') client.emit('Page.frameNavigated',{frame:{url:'https://chatgpt.com/c/fixture'}});
   if(scenario==='network-send') client.emit('Network.requestWillBeSent',{requestId:'detective',request:{method:'POST',url:'https://chatgpt.com/backend-api/conversation'}});
 }
 if(name==='uploadAttachmentViaDataTransfer'){
   if(scenario==='drop') throw Error('Attachment did not appear in ChatGPT composer.');
   const reqs=[['POST','https://chatgpt.com/backend-api/files'],['PUT','https://blob.oaiusercontent.com/files/fixture/raw'],['POST','https://chatgpt.com/backend-api/files/process_upload_stream']];
   reqs.forEach(([method,url],i)=>{const requestId=String(i);client.emit('Network.requestWillBeSent',{requestId,request:{method,url}});client.emit('Network.responseReceived',{requestId,response:{status:scenario==='no-signal'?500:200}});client.emit('Network.loadingFinished',{requestId});});
   await new Promise(resolve=>setTimeout(resolve,3));
 }
 return true;
}
`,
  );
  for (const [file, names] of Object.entries(functions)) {
    const rel = file.startsWith("actions/") ? "../state.js" : "./state.js";
    put(
      "dist/src/browser/" + file,
      `import {call} from '${rel}';\n` +
        names
          .map((n) =>
            n === "installJavaScriptDialogAutoDismissal"
              ? `export function ${n}() { return () => {}; }`
              : `export async function ${n}(...args) { return call('${n}',...args); }`,
          )
          .join("\n") +
        "\n",
    );
  }
  put(
    "dist/src/browser/pageActions.js",
    Object.keys(functions)
      .filter((f) => f.startsWith("actions/"))
      .map((f) => `export * from './${f}';`)
      .join("\n") +
      "\nexport async function readAssistantSnapshot() { return null; }\n",
  );
  put(
    "dist/src/cli/browserConfig.js",
    "export function mapModelToBrowserLabel(model) { return model; }\n",
  );
}
