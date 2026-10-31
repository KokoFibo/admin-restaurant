-- 02-seed-aisin.sql — data awal. Jalankan SEKALI setelah 01-schema.sql.
-- Harga menu: yuan x 2700, dibulatkan ke ribuan (Rupiah). Foto: kunci "/images/..." = file di folder public proyek;
-- setelah foto dipindah ke Cloudflare R2, kunci diganti dengan "tenants/<id>/menu/<file>.webp" (lihat scripts/upload-images.mjs).

insert into public.plans (code, name, price_idr, ai_monthly_limit, max_menu_items, max_admins) values
  ('basic', 'Basic', 0, 100, 60, 2),
  ('pro', 'Pro', 0, 500, 300, 5)
on conflict (code) do nothing;  -- harga paket: ubah sesuai tarif langgananmu

do $seed$
declare v_tenant uuid; v_cat uuid; v_item uuid;
begin
  insert into public.tenants (slug, restaurant_type, status, phone, address, menu_options, opening_hours)
  values ('aisin', 'vegetarian', 'active', '+86 (021) 8829-1088', 'Jl. Fumin 188, Distrik Jing''an, Shanghai · Gedung A, Taman Zen',
    array['has_egg', 'has_onion', 'is_spicy'], '{"lunch":"11:30-14:30","tea":"14:30-17:00","dinner":"17:30-21:30"}'::jsonb)
  returning id into v_tenant;

  insert into public.tenant_languages (tenant_id, lang, position) values (v_tenant, 'id', 1), (v_tenant, 'zh', 2);
  insert into public.tenant_translations (tenant_id, lang, brand_name, tagline) values
    (v_tenant, 'id', 'Aisin Vegetarian', 'Gastronomi Nabati Zen'),
    (v_tenant, 'zh', '爱心素食', '禅意植物料理');
  insert into public.subscriptions (tenant_id, plan_code, status) values (v_tenant, 'basic', 'active');

  -- contoh meja (tiap meja punya QR berbeda; token dibuat otomatis, ambil/cetak QR dari tab Meja di admin)
  insert into public.restaurant_tables (tenant_id, label, sort) values (v_tenant, 'Meja 1', 10), (v_tenant, 'Meja 2', 20), (v_tenant, 'Meja 3', 30), (v_tenant, 'Meja 4', 40), (v_tenant, 'Meja 5', 50);

  insert into public.categories (tenant_id, slug, glyph, sort) values (v_tenant, 'main', '馔', 10) returning id into v_cat;
  insert into public.category_translations (category_id, lang, tenant_id, name) values (v_cat, 'id', v_tenant, 'Hidangan Utama'), (v_cat, 'zh', v_tenant, '主菜');
  insert into public.categories (tenant_id, slug, glyph, sort) values (v_tenant, 'soup', '汤', 20) returning id into v_cat;
  insert into public.category_translations (category_id, lang, tenant_id, name) values (v_cat, 'id', v_tenant, 'Sup & Kukus'), (v_cat, 'zh', v_tenant, '汤羹');
  insert into public.categories (tenant_id, slug, glyph, sort) values (v_tenant, 'dimsum', '点', 30) returning id into v_cat;
  insert into public.category_translations (category_id, lang, tenant_id, name) values (v_cat, 'id', v_tenant, 'Dim Sum & Camilan'), (v_cat, 'zh', v_tenant, '点心');
  insert into public.categories (tenant_id, slug, glyph, sort) values (v_tenant, 'dessert', '甜', 40) returning id into v_cat;
  insert into public.category_translations (category_id, lang, tenant_id, name) values (v_cat, 'id', v_tenant, 'Penutup'), (v_cat, 'zh', v_tenant, '甜品');
  insert into public.categories (tenant_id, slug, glyph, sort) values (v_tenant, 'drink', '茶', 50) returning id into v_cat;
  insert into public.category_translations (category_id, lang, tenant_id, name) values (v_cat, 'id', v_tenant, 'Minuman & Teh'), (v_cat, 'zh', v_tenant, '茶饮');

  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'dimsum'), 238000, '/images/pangsit-kuah-truffle.webp', false, false, null, 10)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Pangsit Kuah Truffle & Matsutake', 'Kaldu bening matsutake Yunnan dan truffle hitam dalam kulit setipis sayap jangkrik; sekali gigit, kuahnya melimpah.', 'Pangsit kuah ini dibuat dari kulit tipis yang dilipat tangan. Isinya kaldu matsutake Yunnan yang dibekukan lalu dikukus, sehingga meleleh menjadi kuah di dalam. Truffle hitam diparut di atasnya saat disajikan. Gigit pelan, seruput kuahnya lebih dulu, baru nikmati isiannya. Cocok dipasangkan dengan teh pu-erh mentah.', 'Pilihan Chef'),
    (v_item, 'zh', v_tenant, '松露松茸灌汤包', '云南鲜松茸与黑松露文火萃出澄澈菌汤，面皮薄如蝉翼，轻咬汤汁丰盈，山林香气直沁心脾。', '手工折叠的薄皮灌汤包，馅中的云南松茸高汤冻凝后蒸制，入口化为鲜美汤汁。上桌时现刨黑松露。建议先轻咬一口，吮吸汤汁，再品尝馅料。可搭配古树生普茶。', '主厨推荐');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'main'), 346000, '/images/gulung-asparagus-jade.webp', false, false, null, 20)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Gulung Asparagus Jade & Truffle', 'Asparagus muda dibalut kulit tahu buatan tangan, disiram saus truffle hitam dan minyak camelia tekan dingin.', null, 'Musiman'),
    (v_item, 'zh', v_tenant, '黑松露碧玉翡翠卷', '初夏嫩芦笋裹以手工头层鲜腐皮，浇淋特调黑松露甘露与低温冷压山茶油，脆嫩清甘，层次迭起。', null, '时令清欢');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'main'), 400000, '/images/tahu-tiantai-morel.webp', false, false, null, 30)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Tahu Tiantai & Jamur Morel Kuali Tanah', 'Tahu gilingan batu dari kuil Tiantai, jamur morel utuh dan kastanye, dimasak pelan di kuali tanah liat hingga meresap.', null, 'Andalan Restoran'),
    (v_item, 'zh', v_tenant, '瓦煲羊肚菌煨天台山豆腐', '天台古刹柴火手工石磨豆腐，辅以整颗云南深山羊肚菌与板栗，于紫砂瓦煲中文火慢焗，香浓入骨。', null, '镇店招牌');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'dessert'), 211000, '/images/getah-persik-pu-erh.webp', false, false, null, 40)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Getah Persik Pu-erh Matang', 'Biji teratai salju dan getah persik liar direbus dua belas jam dalam kaldu pu-erh matang, manis lembut dengan jejak gaharu.', null, 'Manis Menenangkan'),
    (v_item, 'zh', v_tenant, '禅茶一味 · 普洱素燕窝', '高山天然雪莲子、野生桃胶以古树熟普清汤煨煮十二时辰，润泽清甜，回味泛起淡淡沉香茶韵。', null, '甜润养心');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'dimsum'), 184000, '/images/gulung-renyah-lima-harta.webp', false, false, null, 50)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Gulung Renyah Lima Harta Gunung', 'Rebung muda, malantou, dan jamur shiitake digulung tangan, digoreng pelan hingga keemasan dan renyah.', null, 'Cita rasa Jiangnan'),
    (v_item, 'zh', v_tenant, '春水碧波 · 五色金丝脆卷', '初生春笋丝、马兰头与香菇金丝手工细卷，文火轻炸至色如暖金，外壳酥脆轻薄，内馅满溢山野草木之鲜。', null, '江南风物');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'soup'), 454000, '/images/sup-labu-emas-matsutake.webp', false, false, null, 60)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Sup Labu Emas Matsutake & Jamur Surai Singa', 'Labu dan kastanye dilebur menjadi kuah emas, dengan matsutake Yunnan dan jamur surai singa liar yang gemuk dan harum.', null, 'Pilihan Chef'),
    (v_item, 'zh', v_tenant, '金汤松茸猴头菇', '板栗南瓜融作金汤，吸饱云南头刀松茸与野生猴头菇的饱满丰腴。', null, '主厨推荐');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'soup'), 508000, '/images/jamur-gunung.webp', false, false, null, 70)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Kuali Jamur Gunung Matsutake & Morel', 'Matsutake, morel, jamur kuping hitam, kulit tahu, dan tahu lembut direbus pelan dalam kaldu bening dengan jahe dan goji.', null, 'Hidangan andalan'),
    (v_item, 'zh', v_tenant, '山珍菌菇煲', '松茸、羊肚菌、黑木耳、腐竹与嫩豆腐于清汤中文火慢煲，佐以姜片与枸杞，鲜醇清润。', null, '招牌菜');
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'main'), 292000, null, true, false, null, 80)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Tahu Pasir Emas Telur Asin', 'Tahu lembut berselimut pasir kuning telur asin, renyah di luar dan lembut di dalam.', null, null),
    (v_item, 'zh', v_tenant, '金沙蛋黄豆腐', '嫩豆腐裹金沙咸蛋黄，外酥内嫩，咸香回甘。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'main'), 194000, null, false, true, 2, 90)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Buncis Tumis Kering ala Sichuan', 'Buncis ditumis kering dengan lada Sichuan dan sayur acar; aromanya tajam dan segar.', null, null),
    (v_item, 'zh', v_tenant, '干煸四季豆', '四季豆干煸，花椒与榨菜提香，镬气十足。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'soup'), 157000, null, true, false, null, 100)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Telur Kukus Sutra dengan Jamur', 'Telur kukus selembut sutra dengan shiitake dan enoki dalam kaldu bening.', null, null),
    (v_item, 'zh', v_tenant, '菌菇蒸蛋羹', '蒸蛋滑嫩如丝，铺以香菇与金针菇，清鲜暖胃。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'dessert'), 130000, null, true, false, null, 110)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Puding Susu Kukus Dua Lapis', 'Puding susu dua lapis yang lembut, manis tipis, dengan kacang merah.', null, null),
    (v_item, 'zh', v_tenant, '双皮奶', '双层奶皮滑嫩，微甜，佐以红豆。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'drink'), 157000, null, false, false, null, 120)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Teh Pu-erh Mentah Yiwu (satu teko)', 'Teh pohon tua, pahit-manis yang naik pelan.', null, null),
    (v_item, 'zh', v_tenant, '易武古树生普（一壶）', '古树生普，先苦后甘，回甘悠长。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'drink'), 184000, null, false, false, null, 130)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Teh Putih Anji Mingqian (satu teko)', 'Segar, lembut, dengan seduhan yang jernih.', null, null),
    (v_item, 'zh', v_tenant, '安吉白茶明前（一壶）', '清鲜柔润，汤色清亮。', null, null);
  insert into public.menu_items (tenant_id, category_id, price_idr, image_key, has_egg, is_spicy, spice_level, sort)
  values (v_tenant, (select id from public.categories where tenant_id = v_tenant and slug = 'drink'), 76000, null, false, false, null, 140)
  returning id into v_item;
  insert into public.menu_item_translations (menu_item_id, lang, tenant_id, name, short_description, detail_description, badge) values
    (v_item, 'id', v_tenant, 'Sirup Plum Asam Dingin', 'Plum asam, hawthorn, dan osmanthus; dingin dan menyegarkan.', null, null),
    (v_item, 'zh', v_tenant, '冰镇酸梅汤', '乌梅山楂桂花熬制，冰镇酸甜解腻。', null, null);
end $seed$;

