# Públicos diferentes, notas diferentes

*English version: [README.en.md](README.en.md).*

Primeira Entrega da disciplina de Gestão Estratégica da Tecnologia da Informação (EPS7008, UFSC/EPS). **Tese:** públicos de plataformas diferentes avaliam as mesmas obras de forma diferente - quem dá 10 no IMDb não é quem dá 5 estrelas no Letterboxd. A unidade de análise é o título; o que se mede é a divergência entre plataformas, na posição de cada filme dentro da distribuição da própria plataforma, nunca média contra média.

- **E1 (15/09/2026):** análise exploratória. Este repositório é a engenharia que a sustenta.
- **E2 (24/11/2026):** dashboard, ML não supervisionado, regressão e classificação. -- não implementado

Grupo: **José Eduardo Pereira, Amaury Philippot e Lucas Christian Harmodio Fraile**.

## Pra quem vai analisar

1. O pacote está na pasta compartilhada do Drive: **[eps7008-e1](https://drive.google.com/drive/folders/1bpF9ch74Zx7HU-kKWlJBBUzadIPrWFn7?usp=sharing)** (acesso só pro grupo). Dentro, `pacote-e1-2026-09-13/` tem `silver/` (dimensões e fatos), `gold/` (agregados prontos) e um `README.md` de uma página com o dicionário, o que não fazer e sete perguntas sugeridas. O `.zip` ao lado é a mesma coisa, pra quem quiser baixar.
2. Abre o notebook de setup no Colab: **[00-setup.ipynb](https://colab.research.google.com/drive/1B1ByQMrs4iGZEoBZv3WeCCYJVMmgMFks)** (a cópia em `notebooks/` é a mesma). Ele monta o Drive, carrega as tabelas como views do DuckDB, mostra o padrão de normalização em código e um gráfico de exemplo. Pra trabalhar, salva uma cópia sua na pasta (Arquivo -> Salvar uma cópia no Drive) e deixa o `00-setup` como referência.

   **Antes de rodar, uma vez só:** pasta compartilhada aparece em "Compartilhados comigo", e o `drive.mount` do Colab não monta isso, só o "Meu Drive". Em "Compartilhados comigo", botão direito na `eps7008-e1` -> Organizar -> **Adicionar atalho ao Drive** -> Meu Drive. Com o atalho, o caminho `/content/drive/MyDrive/eps7008-e1/pacote-e1-2026-09-13` que está no notebook funciona pra todo mundo.
3. Lê o README do pacote antes de qualquer gráfico. Os sete pontos de "não fazer" não são estilo, são o que separa resultado de artefato.

O pacote é congelado: o `gold/` pode ser regerado, mas os números da E1 são os desse zip (tag `v0.1-e1-dados`).

## Estrutura

```
datalake/          fora do git (termos de uso). landing -> bronze -> silver -> gold -> pacote
etl/               o pipeline em sql, um script por etapa, com os logs ao lado; run.sh roda tudo
ops/               ferramentas: runner de sql, crawler do tmdb, download das fontes, empacotador, testes
recon/             sessão 1: reconhecimento das fontes (só agregados versionados)
docs/              relatórios das sessões, fontes, README do pacote
notebooks/         setup pro colab
```

## Pipeline

```mermaid
flowchart LR
  subgraph fontes
    imdb[IMDb tsv]
    wd[Wikidata sparql]
    lb[Letterboxd kaggle]
    ml[MovieLens 1m e 32m]
    tmdb[TMDB api]
  end
  subgraph bronze [bronze - tipado, fiel à fonte]
    b_imdb[imdb_basics<br/>imdb_ratings]
    b_wd[wikidata_ponte]
    b_lb[letterboxd_films<br/>letterboxd_ratings]
    b_ml[movielens_links<br/>ml1_*, ml32_ratings<br/>ml32_por_ano]
    b_tmdb[tmdb_filmes]
  end
  subgraph silver [silver - regra de negócio]
    dim[dim_titulo<br/>17.810 filmes]
    ponte[ponte_ids]
    tt[tmdb_titulo]
    pais[titulo_pais]
    fato[fato_notas]
    demo[fato_notas_demografia]
  end
  subgraph gold [gold - pra análise]
    norm[notas_normalizadas]
    div[divergencia_par]
    canon[cobertura_canonicidade]
    deriva[deriva_ml32]
    idade[notas_por_faixa_etaria<br/>gradiente_idade]
    cob[cobertura_*, paises_*, classificacao_br]
  end
  imdb --> b_imdb --> dim
  wd --> b_wd --> ponte
  lb --> b_lb --> fato
  ml --> b_ml --> ponte
  b_ml --> fato
  b_ml --> demo
  b_ml --> deriva
  ponte --> tmdb --> b_tmdb --> tt --> pais
  b_imdb --> fato
  tt --> fato
  dim --> fato --> norm --> div
  dim --> canon
  demo --> idade
  tt --> cob
```

Ordem: `bronze.sql -> processa_tmdb.py -> silver.sql -> silver_tmdb.sql -> silver_notas.sql -> gold.sql -> gold_tmdb.sql -> gold_notas.sql -> checks.py`. `etl/run.sh` faz isso em ~20 s (o crawl do TMDB, 15 min, roda uma vez e fica em `landing/tmdb`). Cada script é idempotente e roda com `ops/run_sql.py`, que executa um `.sql` no DuckDB statement a statement e imprime o que devolver linhas.

## Modelo de dados

O contrato é `dim_titulo`; tudo se junta a ele por `tconst` (id do IMDb). Notas ficam em formato longo - plataforma nova é linha nova - e a normalização (z-score, percentil) só existe no gold, porque muda com o recorte.

```mermaid
erDiagram
  dim_titulo ||--|| ponte_ids : tconst
  dim_titulo ||--o| tmdb_titulo : tconst
  dim_titulo ||--o{ titulo_pais : tconst
  dim_titulo ||--|{ fato_notas : tconst
  dim_titulo ||--o{ fato_notas_demografia : tconst
  fato_notas ||--o| notas_normalizadas : "tconst, plataforma; n_votos 30+"
  notas_normalizadas }|--|{ divergencia_par : "tconst, par"
  dim_titulo ||--o{ deriva_ml32 : tconst

  dim_titulo {
    string tconst PK
    string titulo
    int ano
    int decada
    string generos
    double pct_votos_decada "percent_rank dos votos dentro da década"
    int n_paises
    string pais_unico "só quando n_paises = 1"
    bool tem_us
  }
  ponte_ids {
    string tconst PK
    int tmdb_id "validado por external_ids"
    string letterboxd_slug "wikidata P6127"
    string metodo_join "ambos | wikidata | movielens | tmdb_find | arbitrado_tmdb | corrigido_tmdb | nenhum | nao_validado"
  }
  tmdb_titulo {
    string tconst PK
    int tmdb_id
    double vote_average
    int vote_count
    string original_language
    list production_countries
    string classificacao_br "L 10 12 14 16 18"
    string certificacao_us
  }
  titulo_pais {
    string tconst PK
    string pais PK
  }
  fato_notas {
    string tconst PK
    string plataforma PK "imdb | tmdb | letterboxd | ml32"
    double nota
    double escala_min
    double escala_max
    int n_votos
    date data_coleta
    string tipo_medida "acumulado"
  }
  fato_notas_demografia {
    string tconst PK
    string faixa_etaria PK
    string genero_usuario PK
    double nota_media "ml-1m, escala 1-5"
    int n_notas
    string tipo_medida "janela 2000-2003"
  }
  notas_normalizadas {
    string tconst PK
    string plataforma PK
    double nota_z "z dentro da plataforma"
    double nota_pct "percentil dentro da plataforma"
  }
  divergencia_par {
    string tconst PK
    string plataforma_a PK
    string plataforma_b PK
    double gap_z "z_b - z_a, na população comum do par"
    double gap_pct
  }
  deriva_ml32 {
    string tconst PK
    int ano_avaliacao PK
    int n_notas
    double nota_media
    double desvio_do_ano "contra a média do próprio filme"
  }
```

Dicionário completo, coluna a coluna: `docs/README-tabelao.md`.

## Decisões que estão nos dados

- **Frame:** `titleType = movie`, 5.000+ votos no IMDb, 1930-2023 -> 17.810 filmes. O corte de votos seleciona coisas diferentes em cada década (a elite nos anos 1930, todo lançamento mediano nos 2010); por isso `pct_votos_decada` e a comparação entre décadas dentro de quartil.
- **Ponte Letterboxd -> IMDb** pelo Wikidata (P6127 -> P345): 98,5% do frame com slug no dump. Título+ano foi descartado.
- **`tmdb_id` validado** contra `external_ids.imdb_id` em todas as linhas: 99,97%. Nas 19 divergências MovieLens x Wikidata, o Wikidata acertou 18 e o MovieLens 0.
- **País:** sem país primário. `pais_unico` é o estrato limpo; coprodução é categoria própria; `tem_us` separa "GB sozinho" de "GB com os EUA".
- **Datas:** IMDb e TMDB acumulados de 13/09/2026, Letterboxd e ml-32m de out/2023, ml-1m janela 2000-2003. `tipo_medida` distingue acumulado de janela.
- **Achados de engenharia que já são resultado:** a cobertura do Letterboxd é canonicidade, não defeito; o gradiente de idade do ml-1m era composição da cesta; o Letterboxd é a plataforma que descola das outras (correlação de z 0,76-0,85 contra 0,90-0,93 entre as demais).

Relatórios, em ordem: `recon/relatorio.md` (fontes e corte), `docs/ponte-wikidata.md` (ponte e frame), `docs/confundimento-tmdb.md` (canonicidade e TMDB), `docs/fato-notas.md` (notas e pacote).

## Reproduzir do zero

```bash
python -m venv ops/venv-gestao && ops/venv-gestao/bin/pip install -r ops/requirements.txt
ops/download_fontes.sh                          # ~5 gb em datalake/landing; kaggle não precisou de credencial
etl/run.sh                                      # bronze e silver (~10 s); para e pede o crawl
cp .env.example .env                            # chave do tmdb: https://www.themoviedb.org/settings/api, é preciso registrar o app
ops/venv-gestao/bin/python ops/crawl_tmdb.py    # ~15 min, lê o silver pra saber o que buscar
etl/run.sh                                      # agora vai até o gold (~20 s) e termina nos 26 checks de integridade
ops/empacotar.sh                                # datalake/pacote/pacote-e1-<data>.zip
```

`ops/teste_tmdb.py` exercita crawler, parser e a arbitragem com a API mockada, sem tocar em `datalake/`. Baixar as fontes de novo muda o frame (IMDb, TMDB e Wikidata mudam todo dia); pra reproduzir os números da E1, usa o pacote congelado.

## Dados e licenças

Nenhum dado por título está no git: `datalake/` inteiro é ignorado e os únicos parquets versionados (`recon/`) são contagens por faixa, década e região. Fontes, termos e citações em `docs/fontes.md`.

*This product uses the TMDB API but is not endorsed or certified by TMDB.* MovieLens: Harper & Konstan (2015), ACM TiiS 5(4). IMDb: non-commercial datasets. Letterboxd: dataset de freeth no Kaggle. Wikidata: CC0.
