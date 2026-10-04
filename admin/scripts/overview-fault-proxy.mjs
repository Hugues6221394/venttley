// Test-only loopback fault injection. No credentials, URLs or bodies logged.
import { createServer } from 'node:http';
export async function overviewFaultProxy(upstream, intercept, port=0) {
  if (!['127.0.0.1','localhost'].includes(new URL(upstream).hostname)) throw Error('Local upstream required');
  const control={mode:'normal',calls:0};
  const server=createServer(async(req,res)=>{
    try {
      const parts=[];for await(const chunk of req)parts.push(chunk);
      const body=Buffer.concat(parts);const url=new URL(req.url,upstream);
      const injected=await intercept?.({url,body});
      if(injected){res.writeHead(injected.status??200,{'content-type':'application/json'});res.end(JSON.stringify(injected.data));return;}
      if(url.pathname==='/rest/v1/rpc/admin_overview_panel') {
        control.calls++;
        const panel=JSON.parse(body.toString()||'{}').p_panel;
        if(panel==='reports'&&control.mode==='slow')await new Promise(r=>setTimeout(r,2500));
        if(panel==='reports'&&control.mode==='failed') { res.writeHead(503,{'content-type':'application/json'});res.end('{"message":"Synthetic unavailable source"}');return; }
      }
      const headers=new Headers();for(const [k,v]of Object.entries(req.headers))if(v&&!['host','connection','content-length','accept-encoding'].includes(k))headers.set(k,Array.isArray(v)?v.join(','):v);
      const result=await fetch(url,{method:req.method,headers,body:['GET','HEAD'].includes(req.method)?undefined:body,redirect:'manual',signal:AbortSignal.timeout(12000)});
      const outgoing={};result.headers.forEach((v,k)=>{if(!['content-encoding','content-length','transfer-encoding','connection'].includes(k))outgoing[k]=v;});
      res.writeHead(result.status,outgoing);res.end(Buffer.from(await result.arrayBuffer()));
    }catch{if(!res.headersSent)res.writeHead(502);res.end();}
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});
  return {control,url:`http://127.0.0.1:${server.address().port}`,close:()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections();})};
}
