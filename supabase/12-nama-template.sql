-- 12-nama-template.sql — nama tampilan template 'aisin' menjadi "Arunika". Id teknis 'aisin' TIDAK berubah
-- (tenants.template_id, registri template frontend, tautan pendaftaran ?template=aisin tetap bekerja). Aman diulang.
update public.templates set name = 'Arunika' where id = 'aisin' and name is distinct from 'Arunika';
