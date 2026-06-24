// Sidenotes: clone each Pandoc endnote next to its in-text reference.
//
// Wide screens (CSS breakpoint 1180px): the clone floats in the right
// margin beside the reference; the endnote section is hidden.
// Narrow screens: the clone is hidden until the reference is tapped,
// then expands inline below the sentence.
// No JavaScript: the page falls back to Pandoc's endnotes with
// bidirectional links, untouched.

(function () {
  'use strict';

  var refs = document.querySelectorAll('a.footnote-ref');
  if (refs.length === 0) return;

  var wideQuery = window.matchMedia('(min-width: 1180px)');

  refs.forEach(function (ref) {
    var target = ref.getAttribute('href');
    if (!target || target.charAt(0) !== '#') return;
    var note = document.getElementById(target.slice(1));
    if (!note) return;

    // Footnote bodies are single paragraphs; take their inner HTML and
    // drop the return-arrow backlink, which is meaningless in a clone.
    var body = note.cloneNode(true);
    body.querySelectorAll('a.footnote-back').forEach(function (b) { b.remove(); });
    var parts = [];
    body.querySelectorAll('p').forEach(function (p) { parts.push(p.innerHTML); });
    var html = parts.length ? parts.join('<br>') : body.innerHTML;

    var clone = document.createElement('span');
    clone.className = 'sidenote';
    clone.setAttribute('role', 'note');
    clone.innerHTML = '<span class="sn-num">' + ref.textContent.trim() + '.</span> ' + html;
    ref.insertAdjacentElement('afterend', clone);

    ref.addEventListener('click', function (e) {
      if (wideQuery.matches) {
        // Margin note already visible: flash it instead of jumping.
        e.preventDefault();
        clone.classList.add('sn-target');
        setTimeout(function () { clone.classList.remove('sn-target'); }, 1200);
      } else {
        e.preventDefault();
        clone.classList.toggle('expanded');
      }
    });
  });

  document.body.classList.add('sidenotes-on');
})();
