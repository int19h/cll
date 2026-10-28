/* Inspect the final generated page lists, after Prince resolves counters. */
Prince.trackBoxes = true;
Prince.addEventListener('complete', check_index_pages, false);

function index_box_text(box) {
  if (box.type === 'TEXT') return box.text || '';
  var text = '';
  var children = box.children || [];
  for (var i = 0; i < children.length; i++) text += index_box_text(children[i]);
  return text;
}

function check_index_pages() {
  var lists = document.querySelectorAll('.indexdiv .index-pages, .indexdiv a.indexterm');
  for (var i = 0; i < lists.length; i++) {
    var boxes = lists[i].getPrinceBoxes();
    var text = '';
    for (var j = 0; j < boxes.length; j++) text += index_box_text(boxes[j]);
    var page = '(?:[1-9][0-9]*|[ivxlcdm]+)';
    var valid = new RegExp('^' + page + '(?:-' + page + ')?(?:,\\s*' + page + '(?:-' + page + ')?)*$', 'i');
    if (!valid.test(text.trim())) {
      var label = lists[i].parentNode.textContent.replace(/\s+/g, ' ').slice(0, 120);
      Log.error('Index entry has an unresolved page reference: ' + label + ' [' + text + ']');
      Prince.failStatus = true;
    }
  }
}
