const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'../SandboxedDashboard/Orb/MathAssets');
const ctx=vm.createContext({console});
for(const name of ['markdown-it.min.js','katex.min.js','orb-renderer.js'])vm.runInContext(fs.readFileSync(path.join(root,name),'utf8'),ctx);
const render=ctx.orbRender;
const checks=[
 ['inline math',()=>assert.match(render(String.raw`Use \(x^2\) and $y^2$.`),/class="katex"/)],
 ['numeric formula',()=>assert.match(render('$2x+1$'),/class="katex"/)],
 ['display suffix preserved',()=>assert.match(render('$$x$$ is the answer.'),/is the answer/)],
 ['currency preserved',()=>assert.match(render('Price $15 and $20.'),/\$15 and \$20/)],
 ['display brackets',()=>assert.match(render(String.raw`\[\frac{1}{2}\]`),/math-block/)],
 ['multiline aligned',()=>assert.doesNotMatch(render(String.raw`$$
\begin{aligned}x&=1\\y&=2\end{aligned}
$$`),/katex-error/)],
 ['code opaque',()=>{let out=render('```js\n"$not_math$"\n```');assert.doesNotMatch(out,/class="katex"/);assert.match(out,/\$not_math\$/)}],
 ['nested lists',()=>assert.match(render('- Outer\n  - Inner'),/<ul>\n<li>Outer\n<ul>/)],
 ['empty table cell',()=>assert.match(render('| a | b |\n| --- | --- |\n| x | |'),/<td><\/td>/)],
 ['escaped table pipe',()=>assert.match(render('| a | b |\n| --- | --- |\n| x\\|y | z |'),/<td>x\|y<\/td>/)],
 ['html inert',()=>assert.doesNotMatch(render('<script>alert(1)</script>'),/<script>/)],
 ['unsafe links inert',()=>assert.doesNotMatch(render('[x](javascript:alert(1))'),/href="javascript/)],
 ['artifact image',()=>assert.match(render('![chart](sandbox:/mnt/data/chart.png)'),/data-artifact="sandbox:/)],
 ['invalid math readable',()=>{let out=render(String.raw`$$\frac{$$`);assert.match(out,/katex-error/);assert.match(out,/frac/)}],
 ['incomplete math readable',()=>assert.match(render(String.raw`Before \(x+`),/Before/)],
 ['latex cannot make javascript link',()=>assert.doesNotMatch(render(String.raw`$$\href{javascript:alert(1)}{x}$$`),/href="javascript/)],
 ['long transcript',()=>assert.equal((render(Array(200).fill('## Heading\n\nText with **bold**.').join('\n\n')).match(/<h2>/g)||[]).length,200)]
];
for (const name of ['chatgpt-rich.md','cursor-live.md','grok-live.md']) {
 checks.push(['provider corpus '+name,()=>{
  const out=render(fs.readFileSync(path.join(__dirname,'fixtures',name),'utf8'));
  assert.match(out,/<table>/);assert.match(out,/class="katex"/);assert.match(out,/<ul>\n<li>[^]*<ul>/);
  assert.match(out,/copy-code/);assert.doesNotMatch(out,/katex-error/);
 }]);
}
for(const [name,test] of checks){test();console.log('PASS',name)}
console.log(checks.length,'renderer checks passed');
