import {render} from 'solid-js/web';
import {createSignal} from 'solid-js';
import {UserTurn} from '../src/Transcript';
import {MentionProjectContext} from '../src/PromptEditor';
import '../src/styles.css';
const [sent,setSent]=createSignal('');
render(()=><MentionProjectContext.Provider value={()=>'health'}><main class="scroll" style={{padding:'200px 50px'}}><UserTurn text="Review the files" onSend={async text=>{setSent(text);return true;}}/><output>{sent()}</output></main></MentionProjectContext.Provider>,document.getElementById('root')!);
