const navToggle = document.querySelector('.nav-toggle');
const siteNav = document.querySelector('.site-nav');

if (navToggle && siteNav) {
  navToggle.addEventListener('click', () => {
    const open = navToggle.getAttribute('aria-expanded') === 'true';
    navToggle.setAttribute('aria-expanded', String(!open));
    siteNav.classList.toggle('is-open', !open);
  });

  siteNav.addEventListener('click', (event) => {
    if (event.target.matches('a')) {
      navToggle.setAttribute('aria-expanded', 'false');
      siteNav.classList.remove('is-open');
    }
  });
}

const copyButton = document.querySelector('[data-copy-checksum]');
if (copyButton) {
  copyButton.addEventListener('click', async () => {
    const checksum = document.querySelector('#checksum')?.textContent?.trim();
    if (!checksum) return;
    try {
      await navigator.clipboard.writeText(checksum);
      copyButton.textContent = '복사됨';
      setTimeout(() => { copyButton.textContent = '복사'; }, 1600);
    } catch {
      copyButton.textContent = '직접 선택해 주세요';
    }
  });
}

