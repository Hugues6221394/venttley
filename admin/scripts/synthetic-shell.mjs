// Capture only shared chrome. Never reuse a prior run's artifacts or serialize
// real queue contents, account names, badge values, form values or RSC payloads.
export async function syntheticShell(page) {
  return page.evaluate(() => {
    const live = document.querySelector('.operator-shell-v2');
    if (!live) throw Error('Synthetic capture requires the operator shell');
    const shell = live.cloneNode(true);
    shell.querySelector('main').innerHTML = '<section class="operator-queue-panel" aria-label="Synthetic attention fixture"></section>';
    shell.querySelectorAll('script,dialog,#staff-account-menu').forEach(node => node.remove());
    shell.querySelectorAll('.operator-page-link').forEach(link => {
      [...link.children].slice(1).forEach(node => node.remove());
    });
    const header = shell.querySelector('header');
    header.querySelectorAll('button').forEach(button => {
      if (button.getAttribute('aria-label') === 'Account menu') button.textContent = 'Sample Operator';
      if (button.matches('.inbox-bell') || button.getAttribute('aria-label')?.toLowerCase().includes('notification') || button.querySelector('.inbox-bell-count')) {
        button.textContent = 'Notifications';
        button.setAttribute('aria-label', 'Synthetic notification control');
      }
    });
    shell.querySelectorAll('.inbox-queue-badge,.inbox-bell-count').forEach(node => node.remove());
    shell.querySelectorAll('input,textarea').forEach(node => {
      node.value = ''; node.removeAttribute('value'); node.textContent = '';
    });
    shell.querySelectorAll('input[type=hidden]').forEach(node => node.remove());
    shell.querySelectorAll('a').forEach(node => node.setAttribute('href', '#'));
    shell.querySelectorAll('form').forEach(node => node.removeAttribute('action'));
    shell.querySelector('.operator-breadcrumb').textContent = 'Workspace / Synthetic fixture';
    const css = [...document.styleSheets].flatMap(sheet => {
      try { return [...sheet.cssRules].map(rule => rule.cssText); } catch { return []; }
    }).join('\n');
    return `<!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style></head><body>${shell.outerHTML}</body></html>`;
  });
}
