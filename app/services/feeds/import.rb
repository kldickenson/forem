# TODO: [rhymes]
# => add Feeds::ImportUser to fetch a single user
# => add Feeds::ValidateFeedUrl to validate a single feed URL
module Feeds
  class Import
    def self.call
      new.call
    end

    # TODO: add `users` param
    def initialize
      @users = User.where.not(feed_url: [nil, ""])

      # NOTE: should these be configurable? Currently they are the result of empiric
      # tests trying to find a balance between memory occupation and speed
      @users_batch_size = 50
      @num_fetchers = 8
      @num_parsers = 4
    end

    def call
      total_articles_count = 0

      users.in_batches(of: users_batch_size) do |batch_of_users|
        feeds_per_user_id = fetch_feeds(batch_of_users)
        Rails.logger.error("feeds::import::feeds_per_user_id.length: #{feeds_per_user_id.length}")

        feedjira_objects = parse_feeds(feeds_per_user_id)
        Rails.logger.error("feeds::import::feedjira_objects.length: #{feedjira_objects.length}")

        # NOTE: doing this sequentially to avoid locking problems with the DB
        # and unnecessary conflicts
        articles = feedjira_objects.flat_map do |user_id, feed|
          # TODO: replace `feed` with `feed.url` as `RssReader::Assembler`
          # only actually needs feed.url
          user = batch_of_users.detect { |u| u.id == user_id }
          create_articles_from_user_feed(user, feed)
        end
        Rails.logger.error("feeds::import::articles.length: #{articles.length}")

        total_articles_count += articles.length
        Rails.logger.error("feeds::import::total_articles_count: #{total_articles_count}")

        articles.each { |article| Slack::Messengers::ArticleFetchedFeed.call(article: article) }
      end

      total_articles_count
    end

    private

    attr_reader :users, :users_batch_size, :num_fetchers, :num_parsers

    # TODO: put this in separate service object
    def fetch_feeds(batch_of_users)
      data = batch_of_users.pluck(:id, :feed_url)

      result = Parallel.map(data, in_threads: num_fetchers) do |user_id, url|
        response = HTTParty.get(url.strip, timeout: 10)

        [user_id, response.body]
      rescue StandardError => e
        # TODO: add better exception handling
        # For example, we should stop pulling feeds that return 404 and disable them?

        report_error(
          e,
          feeds_import_info: {
            user_id: user_id,
            url: url,
            error: "Feeds::Import::FetchFeedError"
          },
        )

        next
      end

      batch_of_users.update_all(feed_fetched_at: Time.current)

      result.compact.to_h
    end

    # TODO: put this in separate service object
    def parse_feeds(feeds_per_user_id)
      result = Parallel.map(feeds_per_user_id, in_threads: num_parsers) do |user_id, feed_xml|
        parsed_feed = Feedjira.parse(feed_xml)

        [user_id, parsed_feed]
      rescue StandardError => e
        # TODO: add better exception handling (eg. rescueing Feedjira::NoParserAvailable separately)
        report_error(
          e,
          feeds_import_info: {
            user_id: user_id,
            error: "Feeds::Import::ParseFeedError"
          },
        )

        next
      end

      result.compact.to_h
    end

    # TODO: currently this is exactly as in RSSReader, but we might find
    # avenues for optimization, like:
    # 1. why are we sending N exists query to the DB, one per each item, can we fetch them all?
    # 2. should we queue a batch of workers to create articles, but then, following issues ensue:
    # => synchronization on write (table/row locking)
    # => what happens if 2 jobs are in the queue for the same article?
    # => what happens if they stay in the queue for long and the next iteration of the feeds importer starts?
    def create_articles_from_user_feed(user, feed)
      articles = []

      feed.entries.reverse_each do |item|
        next if medium_reply?(item) || article_exists?(user, item)

        feed_source_url = item.url.strip.split("?source=")[0]
        article = Article.create!(
          feed_source_url: feed_source_url,
          user_id: user.id,
          published_from_feed: true,
          show_comments: true,
          body_markdown: RssReader::Assembler.call(item, user, feed, feed_source_url),
          organization_id: nil,
        )

        articles.append(article)
      rescue StandardError => e
        # TODO: add better exception handling
        report_error(
          e,
          feeds_import_info: {
            username: user.username,
            feed_url: user.feed_url,
            item_count: get_item_count_error(feed),
            error: "Feeds::Import::CreateArticleError:#{item.url}"
          },
        )

        next
      end

      articles
    end

    def get_host_without_www(url)
      url = "http://#{url}" if URI.parse(url).scheme.nil?
      host = URI.parse(url).host.downcase
      host.start_with?("www.") ? host[4..] : host
    end

    def medium_reply?(item)
      get_host_without_www(item.url.strip) == "medium.com" &&
        !item[:categories] &&
        content_is_not_the_title?(item)
    end

    def content_is_not_the_title?(item)
      # [[:space:]] removes all whitespace, including unicode ones.
      content = item.content.gsub(/[[:space:]]/, " ")
      title = item.title.delete("…")
      content.include?(title)
    end

    def article_exists?(user, item)
      title = item.title.strip.gsub('"', '\"')
      feed_source_url = item.url.strip.split("?source=")[0]
      relation = user.articles
      relation.where(title: title).or(relation.where(feed_source_url: feed_source_url)).exists?
    end

    def report_error(error, metadata)
      Rails.logger.error("feeds::import::error::#{error.class}::#{metadata}")
      Rails.logger.error(error)
    end

    def get_item_count_error(feed)
      if feed
        feed.entries ? feed.entries.length : "no count"
      else
        "NIL FEED, INVALID URL"
      end
    end
  end
end
