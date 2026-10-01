import {it,expect} from 'vitest';
import {trackScrollbarHover} from '../src/scrollbarHover';
it('reveals on edge proximity even when the event targets outside the scroller; hides on leaving',()=>{
 const scroller=document.createElement('div');scroller.className='scroll';document.body.append(scroller);
 Object.defineProperties(scroller,{clientHeight:{value:500},scrollHeight:{value:2000}});
 scroller.getBoundingClientRect=()=>({left:100,right:800,top:50,bottom:550,width:700,height:500,x:100,y:50,toJSON(){}});
 const stop=trackScrollbarHover();
 const thumb=document.querySelector<HTMLElement>('.transcript-scroll-thumb')!;
 const move=(x:number,y:number)=>document.dispatchEvent(new MouseEvent('pointermove',{clientX:x,clientY:y,bubbles:true}));
 expect(thumb.hidden).toBe(true);
 move(775,250);expect(thumb.hidden).toBe(false);expect(thumb.style.left).toBe('789px');
 expect(thumb.style.height).toBe('123px');
 expect(thumb.classList.contains('hovered')).toBe(false);
 move(793,100);expect(thumb.classList.contains('hovered')).toBe(true);
 move(775,100);expect(thumb.classList.contains('hovered')).toBe(false);
 scroller.scrollTop=1500;scroller.dispatchEvent(new Event('scroll'));
 expect(thumb.style.top).toBe('423px');
 move(400,250);expect(thumb.hidden).toBe(false); // stays visible briefly after scrolling
 expect(thumb.style.maskImage).toContain('linear-gradient');
 move(775,250);window.dispatchEvent(new Event('blur'));expect(thumb.hidden).toBe(true);
 stop();expect(thumb.isConnected).toBe(false);scroller.remove();
});
it('keeps drag sensitivity stable when virtualization changes scroll height',()=>{
 const scroller=document.createElement('div');scroller.className='scroll';document.body.append(scroller);
 let height=2000;
 Object.defineProperties(scroller,{clientHeight:{value:500},scrollHeight:{get:()=>height}});
 scroller.getBoundingClientRect=()=>({left:100,right:800,top:50,bottom:550,width:700,height:500,x:100,y:50,toJSON(){}});
 const stop=trackScrollbarHover();const thumb=document.querySelector<HTMLElement>('.transcript-scroll-thumb')!;
 thumb.setPointerCapture=()=>{};thumb.hasPointerCapture=()=>false;
 const pointer=(target:EventTarget,type:string,y:number)=>{
  const event=new MouseEvent(type,{clientX:795,clientY:y,button:0,bubbles:true});
  Object.defineProperty(event,'pointerId',{value:1});target.dispatchEvent(event);
 };
 pointer(document,'pointermove',100);pointer(thumb,'pointerdown',100);
 pointer(document,'pointermove',110);const first=scroller.scrollTop;
 height=4000;
 pointer(document,'pointermove',120);expect(scroller.scrollTop).toBeCloseTo(first*2);
 pointer(document,'pointerup',120);stop();scroller.remove();
});
