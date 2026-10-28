/*
 * This code turns an index entry like:
 *
 * na: 6, 6, 7, 8, 8, 9, 10, 11, 11, 16, 17, 20, 21, 22, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 37, 38, 38, 38
 *
 * into:
 *
 * na: 6-11, 16-17, 20-22, 37-38
 *
 * Some bits came from http://www.princexml.com/howcome/2015/index/musick.html
 *
 * Much else came from
 * http://www.princexml.com/forum/topic/3129/merge-repeated-cross-links?p=1#15392
 * ; much thanks to mikeday for his help!
 *
 */

Prince.trackBoxes = true;
window.addEventListener("load", prep_index, false);
Prince.addScriptFunc( "index_term", index_term );

/* Takes an arbitrary number of page number arguments, and returns
 * text from them, after de-duplication, so:
 *
 * index_term( 1, 2, 3, 3, 3, 7, 7, 7 )
 *
 * becomes:
 *
 * "1-3, 7"
 *
 */
function index_term()
{
  var text='';
  var last=null;
  var range=false;
  // console.log('it: ' + arguments)
  for(var i=0; i<arguments.length; i++)
  {
    var arg = arguments[i];
    // Preserve the existing omission of unresolved initial page references.
    if( last === null && Number(arg) === 0 ) continue;
    if( last != arg ) {
      if( last !== null && Number(arg) == (Number(last) + 1) ) {
        range = true;
        last = arg;
      } else {
        if( range == true ) {
          // If we're in a range but the argument is *not* in said
          // range, we end the range
          text = text + "-" + last
          range = false;
        }

        if( text != '' ) {
          text = text + ", "
        }
        text = text + arg;
        last = arg;
      }
    }
  }

  // Boo code repitition
  if( range == true ) {
    // If we're in a range but the argument is *not* in said
    // range, we end the range
    text = text + "-" + last
    range = false;
  }

  return text;
}

/* The basics here come from
 * http://www.princexml.com/forum/topic/3129/merge-repeated-cross-links?p=1#15392
 * ; much thanks to mikeday for his help!
 *
 * The goal here is to turn index dt elements from:
 *
 * <dt>little: <a class="indexterm" href="#idm217009053168">Three-part tanru grouping with bo</a>, <a class="indexterm" href="#idm217009048368">Three-part tanru grouping with bo</a>, <a class="indexterm" href="#idm217009044128">Three-part tanru grouping with bo</a></dt>
 *
 * to:
 *
 * <dt>little: <span class="index-pages" style="content: prince-script(index_term, target-counter(url(#idm217009053168), page), target-counter(url(#idm217009048368), page), target-counter(url(#idm217009044128), page))"></span></dt>
 *
 * and then the actual index collapsing happens in index_term above.
 */
function hidden_index_target(link)
{
  var href = link.getAttribute('href');
  if (!href || href.charAt(0) !== '#') return false;
  var target = document.getElementById(href.slice(1));
  while (target) {
    if (target.getAttribute && (' ' + (target.getAttribute('class') || '').replace(/\s+/g, ' ') + ' ')
        .indexOf(' display-none ') !== -1) return true;
    target = target.parentNode;
  }
  return false;
}

function prep_index()
{
  var indexes = document.getElementsByClassName('indexdiv');
  for (var i = 0; i < indexes.length; i++) {
    // Entries can disappear, so do not iterate the live collection.
    var entries = Array.prototype.slice.call(indexes[i].getElementsByTagName('dt'));
    for (var j = entries.length - 1; j >= 0; j--) {
      var entry = entries[j];
      var allLinks = entry.getElementsByTagName('a');
      var following = entry.nextElementSibling;
      var hasDetails = following && following.nodeName.toLowerCase() === 'dd';
      if (!allLinks.length) {
        if (hasDetails && !following.textContent.trim()) {
          entry.parentNode.removeChild(following);
          entry.parentNode.removeChild(entry);
        }
        continue;
      }
      var links = [];
      for (var k = 0; k < allLinks.length; k++) {
        if (!hidden_index_target(allLinks[k])) links.push(allLinks[k]);
      }
      var firstText = '';
      for (var n = 0; n < entry.childNodes.length; n++) {
        if (entry.childNodes[n].nodeName === '#text') {
          firstText = entry.childNodes[n].nodeValue;
          break;
        }
      }
      if (!links.length) {
        // Retain a heading when its subentries still have page references.
        if (hasDetails && following.textContent.trim()) {
          entry.textContent = firstText.replace(/,\s*$/, '');
        } else {
          if (hasDetails) entry.parentNode.removeChild(following);
          entry.parentNode.removeChild(entry);
        }
        continue;
      }
      var text = '<span class="index-pages" style="content: prince-script(index_term, ';
      for (var k = 0; k < links.length; k++) {
        if (k) text += ', ';
        text += 'target-counter(url(' + links[k].getAttribute('href') + '), page)';
      }
      entry.innerHTML = firstText + text + ')"></span>';
    }
  }
}
