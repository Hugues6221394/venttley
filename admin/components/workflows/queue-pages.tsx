import Link from 'next/link';
import {workQueueHref,type WorkCursor} from '@/lib/workflow-model';

export type QueuePagesProps={path:string;filter:Record<string,string>;next:WorkCursor|null;hasCursor:boolean};
export function QueuePages({path,filter,next,hasCursor}:QueuePagesProps) {
  return <nav className="operator-actions" aria-label="Queue pages">
    {hasCursor&&<Link className="btn-secondary" prefetch={false} href={workQueueHref(path,filter)}>First page</Link>}
    {next&&<Link className="btn-secondary" prefetch={false} href={workQueueHref(path,filter,next)}>Next page</Link>}
  </nav>;
}
