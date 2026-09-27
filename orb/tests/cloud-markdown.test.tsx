import {render,screen,cleanup} from '@solidjs/testing-library';
import {afterEach,expect,it} from 'vitest';
import {MdView,parseMarkdown} from '../src/Markdown';
afterEach(cleanup);
it('renders Grok single-line display math without leftover dollar signs',()=>{
 const {container}=render(()=><MdView text={'Formula\n$$x^2$$\n\n\\[y^2\\]'}/>);
 expect(container.querySelectorAll('.katex-display')).toHaveLength(2);
 expect(container.textContent).not.toContain('$');
});
it('renders provider tables, code and original TeX without duplicating formulas', () => {
 const {container}=render(()=><MdView text={'## Result\n\n| Year | Value |\n| --- | --- |\n| 2026 | 42 |\n\n$$\nx^2\n$$\n\nInline \\(x+1\\) and $x+2$.'}/>);
 expect(screen.getByRole('table')).toBeTruthy();
 expect(container.querySelectorAll('.katex')).toHaveLength(3);
 expect(parseMarkdown('$$\nx^2\n$$')).toEqual([{t:'math',text:'x^2'}]);
});
it('keeps currency and code literal and disables executable TeX links',()=>{
 const {container}=render(()=><MdView text={'Price $15 and $20. `\\(x\\)`\n\n$$\n\\href{javascript:alert(1)}{bad}\n$$'}/>);
 expect(container.textContent).toContain('Price $15 and $20.');
 expect(container.querySelector('code')?.textContent).toBe('\\(x\\)');
 expect(container.querySelector('a[href^="javascript:"]')).toBeNull();
});

it('renders safe shared images and ordered steps',()=>{
 const {container}=render(()=><MdView text={'![Chart](https://example.com/chart.png)\n\n1. First\n2. Second'}/>);
 expect(container.querySelector('img')?.getAttribute('referrerpolicy')).toBe('no-referrer');
 expect(container.querySelectorAll('ol li')).toHaveLength(2);
});

it('displays escaped text from ChatGPT as literal text',()=>{
 const {container}=render(()=><MdView text={'ORB\\_MODEL\\_CHECK and \\*literal\\*'}/>);
 expect(container.textContent).toBe('ORB_MODEL_CHECK and *literal*');
 expect(container.querySelector('em')).toBeNull();
});
