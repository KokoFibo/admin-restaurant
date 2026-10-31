import Sortable from 'sortablejs';
/** v-sortable="{ enabled, ids, onSort(ids) }" — urutan baru dihitung dari data, bukan dari DOM (DOM dikembalikan, Vue yang merender ulang). */
export const vSortable = {
  mounted(el: any, { value }: any) {
    el.__v = value;
    el.__s = Sortable.create(el, { handle: '.drag', animation: 150, ghostClass: 'drag-ghost', disabled: !value.enabled, onEnd(evt: any) {
      const { oldIndex, newIndex, item, from } = evt; if (oldIndex == null || newIndex == null || oldIndex === newIndex) return;
      from.removeChild(item); from.insertBefore(item, from.children[oldIndex] ?? null);
      const ids = [...el.__v.ids]; ids.splice(newIndex, 0, ids.splice(oldIndex, 1)[0]); el.__v.onSort(ids);
    } });
  },
  updated(el: any, { value }: any) { el.__v = value; el.__s.option('disabled', !value.enabled); },
  unmounted(el: any) { el.__s?.destroy(); },
};
